#include <ysclass.h>

#include "fs.h"
#include "fsrvbrecovery.h"
#include "fsrvbteampicture.h"

// RvB: see fsrvbrecovery.h (YSFlight RvB Edition, 2026-09-30).

static const double FSRVB_TRANSIT_ALT[2]={1000.0,1500.0};
static const double FSRVB_APPROACH_DIST=7000.0;   // m from the base: hand over to the landing autopilot
static const double FSRVB_APPROACH_TIMEOUT=300.0; // s: try the approach again
static const double FSRVB_TOUCHDOWN_INSET=250.0;  // m from the threshold
static const double FSRVB_ROLLOUT_SPEED=20.0;     // m/s: start taxiing below this
static const double FSRVB_TAXI_FAST=25.0;         // m/s on the runway (humans taxi fast)
static const double FSRVB_TAXI_SLOW=12.0;         // m/s off the runway
static const double FSRVB_TAXI_TURN=4.0;          // m/s in sharp turns
static const double FSRVB_LINEUP_SPEED=2.0;         // m/s: turn onto the centre line almost in place
static const double FSRVB_SUPPLY_SEARCH=4000.0;   // m: supply objects farther than this are ignored
static const double FSRVB_REFUEL_TIME=5.0;        // s next to a supply object
static const double FSRVB_REFUEL_TIME_NOSUPPLY=8.0;// s in place when the base has none
static const double FSRVB_RUNWAY_SEARCH=5000.0;   // m from the base
static const double FSRVB_DIRECT_TO_START=1500.0;  // m: closer than this, taxi straight to the runway start
static const double FSRVB_TAKEOFF_CLIMB=500.0;    // m above the runway
static const double FSRVB_HOLD_MAX=30.0;          // s holding short at most
static const double FSRVB_AHEAD_CLEAR=70.0;       // m: stop for anything this close ahead
static const double FSRVB_CARRIER_TAXI_TIMEOUT=45.0; // s: YS carrier taxi stuck -> launch from where it is
static const double FSRVB_CIRCLE_RADIUS=80.0;     // m
static const double FSRVB_CIRCLE_TIME=20.0;       // s near a waypoint without reaching it
static const double FSRVB_HOLD_GIVEUP=10.0;       // s waiting for something ahead before going anyway
static const double FSRVB_HOLD_SHORT_DIST=80.0;   // m before joining the runway

/* static */ int FsRvbRecovery::nTotalLanding=0;
/* static */ int FsRvbRecovery::nTotalRefuel=0;
/* static */ int FsRvbRecovery::nTotalTakeoff=0;

FsRvbRecovery::FsRvbRecovery()
{
	stage=STAGE_IDLE;
	stageTimer=0.0;
	hdgErr=0.0;
	baseType=FsSimInfo::AIRPORT;
	carrierKey=YSNULLHASHKEY;
	basePos=YsOrigin();
	rwyValid=YSFALSE;
	pathIdx=0;
	nPath=0;
	taxiSpeed[0]=FSRVB_TAXI_FAST;
	taxiSpeed[1]=FSRVB_TAXI_SLOW;
	supplyKey=YSNULLHASHKEY;
	canRefuel=YSFALSE;
	nearWaypointTime=0.0;
	holdTimer=0.0;
	nRefuel=0;
	nGoAround=0;
	landThreshold=YsOrigin();
	landDir=YsZVec();
	transitAP=NULL;
	landingAP=NULL;
	takeoffAP=NULL;
	carrierTaxiAP=NULL;
}

FsRvbRecovery::~FsRvbRecovery()
{
	ClearSubAutopilot();
}

void FsRvbRecovery::ClearSubAutopilot(void)
{
	if(NULL!=transitAP)
	{
		FsAutopilot::Delete(transitAP);
		transitAP=NULL;
	}
	if(NULL!=landingAP)
	{
		FsAutopilot::Delete(landingAP);
		landingAP=NULL;
	}
	if(NULL!=takeoffAP)
	{
		FsAutopilot::Delete(takeoffAP);
		takeoffAP=NULL;
	}
	if(NULL!=carrierTaxiAP)
	{
		FsAutopilot::Delete(carrierTaxiAP);
		carrierTaxiAP=NULL;
	}
}

/* static */ const char *FsRvbRecovery::StageToStr(STAGE s)
{
	switch(s)
	{
	default:
	case STAGE_IDLE:
		return "IDLE";
	case STAGE_TRANSIT:
		return "TRANSIT";
	case STAGE_PATTERN:
		return "PATTERN";
	case STAGE_APPROACH:
		return "APPROACH";
	case STAGE_ROLLOUT:
		return "ROLLOUT";
	case STAGE_TAXI_TO_SUPPLY:
		return "TAXI_TO_SUPPLY";
	case STAGE_REFUEL:
		return "REFUEL";
	case STAGE_TAXI_TO_RUNWAY:
		return "TAXI_TO_RUNWAY";
	case STAGE_LINEUP:
		return "LINEUP";
	case STAGE_CARRIER_TAXI:
		return "CARRIER_TAXI";
	case STAGE_TAKEOFF:
		return "TAKEOFF";
	case STAGE_DONE:
		return "DONE";
	}
}

void FsRvbRecovery::SetStage(STAGE s)
{
	stage=s;
	stageTimer=0.0;
	holdTimer=0.0;
}

FsRvbRecovery::STAGE FsRvbRecovery::GetStage(void) const
{
	return stage;
}

double FsRvbRecovery::GetStageTime(void) const
{
	return stageTimer;
}

int FsRvbRecovery::GetLandingPhase(void) const
{
	return (NULL!=landingAP ? landingAP->landingPhase : -1);
}

YSBOOL FsRvbRecovery::IsBusy(void) const
{
	return (STAGE_IDLE!=stage && STAGE_DONE!=stage ? YSTRUE : YSFALSE);
}

YSBOOL FsRvbRecovery::IsInTheAirPhase(void) const
{
	return (STAGE_TRANSIT==stage ? YSTRUE : YSFALSE);
}

YSBOOL FsRvbRecovery::IsSteering(void) const
{
	return (STAGE_PATTERN==stage ? YSTRUE : YSFALSE);
}

const FsRvbSteer &FsRvbRecovery::GetSteer(void) const
{
	return steer;
}

void FsRvbRecovery::Stop(void)
{
	ClearSubAutopilot();
	SetStage(STAGE_IDLE);
}

void FsRvbRecovery::ChooseBase(FsAirplane &air,const FsRvbTeamPicture &pic)
{
	// Airfields only while carrier recoveries are unreliable; a carrier when the team has no airfield.
	const FsRvbMapInfo::Base *b=NULL;
	double bestD2=YsInfinity;
	for(auto &cand : pic.map.base)
	{
		const double d2=(cand.pos-air.GetPosition()).GetSquareLengthXZ()+(FsSimInfo::CARRIER==cand.type ? 1e12 : 0.0);
		if(cand.iff==air.iff && d2<bestD2)
		{
			b=&cand;
			bestD2=d2;
		}
	}
	if(NULL!=b)
	{
		baseType=b->type;
		baseTag=b->tag;
		carrierKey=b->carrierKey;
		basePos=b->pos;
	}
	else
	{
		baseType=FsSimInfo::AIRPORT;
		baseTag.Set("");
		carrierKey=YSNULLHASHKEY;
		basePos=pic.map.MakePosition(air.iff,10000.0,0.0,0.0);
	}
}

void FsRvbRecovery::ChooseRunway(const FsAirplane &air,const FsRvbTeamPicture &pic)
{
	// The own runway whose start is nearest (on the ground: to the aircraft, in the air: to the base).
	const YsVec3 ref=(YSTRUE==air.Prop().IsOnGround() ? air.GetPosition() : basePos);
	rwyValid=YSFALSE;
	double bestD2=FSRVB_RUNWAY_SEARCH*FSRVB_RUNWAY_SEARCH;
	for(auto &rwy : pic.map.runway)
	{
		const double d2=(rwy.end[0]-ref).GetSquareLengthXZ();
		if(rwy.iff==air.iff && d2<bestD2)
		{
			rwyEnd[0]=rwy.end[0];
			rwyEnd[1]=rwy.end[1];
			bestD2=d2;
			rwyValid=YSTRUE;
		}
	}
}

void FsRvbRecovery::StartRtb(FsAirplane &air,FsSimulation *,const FsRvbTeamPicture &pic)
{
	ClearSubAutopilot();
	ChooseBase(air,pic);
	ChooseRunway(air,pic);
	transitAP=FsGotoPosition::Create();
	SetStage(STAGE_TRANSIT);
}

void FsRvbRecovery::StartOnGround(FsAirplane &air,FsSimulation *,const FsRvbTeamPicture &pic)
{
	ClearSubAutopilot();
	ChooseBase(air,pic);
	if(NULL!=air.Prop().OnThisCarrier())
	{
		BeginCarrierLaunch(air);
		return;
	}
	ChooseRunway(air,pic);
	BeginTaxiToRunway(air);
}

void FsRvbRecovery::BeginApproach(FsAirplane &air,FsSimulation *sim)
{
	ClearSubAutopilot();
	if(FsSimInfo::CARRIER==baseType)
	{
		const FsGround *carrier=sim->FindGround(carrierKey);
		if(NULL!=carrier && YSTRUE==carrier->IsAlive())
		{
			landingAP=FsLandingAutopilot::Create();
			landingAP->autoClearRunway=YSFALSE;
			landingAP->useRunwayClearingPathIfAvailable=YSFALSE;
			landingAP->SetAirplaneInfo(air,YsPi/2.0);
			landingAP->SetIls(air,sim,carrier);
			SetStage(STAGE_APPROACH);
			return;
		}
	}
	else if(YSTRUE==rwyValid)
	{
		// Land in the direction that has us on the approach side already.
		// end[0] -> end[1] is the known-good direction (a runway start spot and its heading).
		landDir=YsUnitVector(rwyEnd[1]-rwyEnd[0]);
		landThreshold=rwyEnd[0];
		landDir.SetY(0.0);
		landDir.Normalize();
		pattern.Start(air,landThreshold,landDir,(rwyEnd[1]-rwyEnd[0]).GetLength());
		SetStage(STAGE_PATTERN);
		return;
	}

	// Nowhere to land: give the aircraft back to the tactical AI.
	SetStage(STAGE_IDLE);
}

void FsRvbRecovery::BeginFinal(FsAirplane &air,FsSimulation *sim)
{
	// At the gate: YS lands it straight in.  If YS would not take it straight in, fly the pattern again.
	ClearSubAutopilot();
	landingAP=FsLandingAutopilot::Create();
	landingAP->autoClearRunway=YSFALSE;
	landingAP->useRunwayClearingPathIfAvailable=YSFALSE;
	landingAP->SetAirplaneInfo(air,YsPi/2.0);
	landingAP->SetVfr(air,sim,landThreshold+landDir*FSRVB_TOUCHDOWN_INSET,landDir);
	if(FsLandingAutopilot::PHASE_BASE_TO_FINAL==landingAP->landingPhase)
	{
		SetStage(STAGE_APPROACH);
		return;
	}
	ClearSubAutopilot();
	++nGoAround;
	pattern.Start(air,landThreshold,landDir,(rwyEnd[1]-rwyEnd[0]).GetLength());
	SetStage(STAGE_PATTERN);
}

void FsRvbRecovery::BeginTaxiToSupply(FsAirplane &air,FsSimulation *sim)
{
	const YsVec3 &pos=air.GetPosition();
	const FsGround *best=NULL;
	double bestD2=FSRVB_SUPPLY_SEARCH*FSRVB_SUPPLY_SEARCH;
	for(int i=0; i<sim->GetNumSupplyVehicle(); ++i)
	{
		const FsGround *s=sim->GetSupplyVehicle(i);
		if(NULL==s || YSTRUE!=s->IsAlive() || s->iff!=air.iff)
		{
			continue;
		}
		const double d2=(s->GetPosition()-pos).GetSquareLengthXZ();
		if(d2<bestD2)
		{
			best=s;
			bestD2=d2;
		}
	}

	nPath=0;
	pathIdx=0;
	nearWaypointTime=0.0;
	canRefuel=(NULL!=best ? YSTRUE : YSFALSE);
	supplyKey=(NULL!=best ? best->SearchKey() : YSNULLHASHKEY);
	if(NULL==best)
	{
		SetStage(STAGE_REFUEL);  // Refuel in place
		return;
	}

	// Along the runway to abeam the supply object, then straight to it.
	const YsVec3 supplyPos=best->GetPosition();
	YsVec3 abeam=pos;
	if(YSTRUE==rwyValid)
	{
		const YsVec3 v=rwyEnd[1]-rwyEnd[0];
		const double t=YsBound(((supplyPos-rwyEnd[0])*v)/v.GetSquareLength(),0.0,1.0);
		abeam=rwyEnd[0]+v*t;
	}
	YsVec3 toSupply=supplyPos-abeam;
	toSupply.SetY(0.0);
	const double standOff=best->Prop().GetOutsideRadius()+air.GetApproximatedCollideRadius()+4.0;
	YsVec3 stop=supplyPos;
	if(YSOK==toSupply.Normalize())
	{
		stop=supplyPos-toSupply*standOff;
	}

	if((abeam-pos).GetSquareLengthXZ()>YsSqr(30.0))
	{
		path[nPath]=abeam;
		taxiSpeed[nPath]=FSRVB_TAXI_FAST;
		++nPath;
	}
	path[nPath]=stop;
	taxiSpeed[nPath]=FSRVB_TAXI_SLOW;
	++nPath;
	SetStage(STAGE_TAXI_TO_SUPPLY);
}

void FsRvbRecovery::BeginTaxiToRunway(FsAirplane &air)
{
	nPath=0;
	pathIdx=0;
	nearWaypointTime=0.0;
	if(YSTRUE!=rwyValid)
	{
		// No own runway nearby: never a blind take-off across the grass.  Stay parked.
		SetStage(STAGE_IDLE);
		return;
	}

	// Take off from end[0] (the runway start) towards end[1].  Near the start (hold-short and ramp spots):
	// straight to it, which follows the short entry taxiway.  Far away: join the runway first.
	const YsVec3 &pos=air.GetPosition();
	const YsVec3 v=rwyEnd[1]-rwyEnd[0];
	if((rwyEnd[0]-pos).GetSquareLengthXZ()>FSRVB_DIRECT_TO_START*FSRVB_DIRECT_TO_START)
	{
		const double t=YsBound(((pos-rwyEnd[0])*v)/v.GetSquareLength(),0.0,1.0);
		path[nPath]=rwyEnd[0]+v*t;
		taxiSpeed[nPath]=FSRVB_TAXI_SLOW;
		++nPath;
	}
	path[nPath]=rwyEnd[0];
	taxiSpeed[nPath]=FSRVB_TAXI_SLOW;
	++nPath;
	SetStage(STAGE_TAXI_TO_RUNWAY);
}

void FsRvbRecovery::BeginCarrierLaunch(FsAirplane &air)
{
	// On the catapult: go.  A carrier YS can auto-taxi on: taxi to the catapult.  Else (ski-jump / no
	// auto-taxi decks): full-power deck run straight ahead.
	const FsGround *carrier=air.Prop().OnThisCarrier();
	const FsAircraftCarrierProperty *carrierProp=(NULL!=carrier ? carrier->Prop().GetAircraftCarrierProperty() : NULL);
	if(NULL!=carrierProp && YSTRUE!=carrierProp->IsOnCatapult(air.GetPosition()) &&
	   YSTRUE==carrierProp->HasCatapult() && YSTRUE!=carrierProp->NoAutoTaxi())
	{
		carrierTaxiAP=FsTaxiingAutopilot::Create();
		carrierTaxiAP->SetMode(FsTaxiingAutopilot::MODE_TAKEOFF_ON_CARRIER);
		SetStage(STAGE_CARRIER_TAXI);
		return;
	}
	BeginDeckLaunch(air);
}

void FsRvbRecovery::BeginDeckLaunch(FsAirplane &air)
{
	const FsGround *carrier=air.Prop().OnThisCarrier();
	YsVec3 dir=air.GetAttitude().GetForwardVector();
	if(NULL!=carrier)
	{
		const FsAircraftCarrierProperty *carrierProp=carrier->Prop().GetAircraftCarrierProperty();
		if(NULL!=carrierProp && YSTRUE==carrierProp->IsOnCatapult(air.GetPosition()))
		{
			dir=carrierProp->GetCatapultVec();
			carrier->GetMatrix().Mul(dir,dir,0.0);
		}
	}
	if(NULL!=carrierTaxiAP)
	{
		FsAutopilot::Delete(carrierTaxiAP);
		carrierTaxiAP=NULL;
	}
	BeginTakeOff(air,NULL,air.GetPosition(),dir);
}

YSBOOL FsRvbRecovery::CirclingWaypoint(const FsAirplane &air,const double dt)
{
	// Close to the waypoint for a long time without reaching it: count it as reached.
	if((path[pathIdx]-air.GetPosition()).GetSquareLengthXZ()<YsSqr(FSRVB_CIRCLE_RADIUS))
	{
		nearWaypointTime+=dt;
	}
	else
	{
		nearWaypointTime=0.0;
	}
	if(FSRVB_CIRCLE_TIME<nearWaypointTime)
	{
		nearWaypointTime=0.0;
		return YSTRUE;
	}
	return YSFALSE;
}

void FsRvbRecovery::BeginTakeOff(FsAirplane &air,FsSimulation *,const YsVec3 &o,const YsVec3 &v)
{
	if(NULL!=takeoffAP)
	{
		FsAutopilot::Delete(takeoffAP);
	}
	YsVec3 dir=v;
	dir.SetY(0.0);
	if(YSOK!=dir.Normalize())
	{
		dir=YsZVec();
	}
	takeoffAP=FsTakeOffAutopilot::Create();
	takeoffAP->UseRunwayCenterLine(o,dir);
	takeoffAP->desigAlt=air.GetPosition().y()+FSRVB_TAKEOFF_CLIMB;
	SetStage(STAGE_TAKEOFF);
}

YSBOOL FsRvbRecovery::SomethingAhead(const FsAirplane &air,const FsRvbTeamPicture &pic) const
{
	// Conga line: wait for anything right ahead.  Two jets nose to nose: only the higher key waits, so
	// they never both wait.  Holding longer than FSRVB_HOLD_GIVEUP means something is parked in the way.
	if(FSRVB_HOLD_GIVEUP<holdTimer)
	{
		return YSFALSE;
	}
	for(auto &c : pic.air)
	{
		if(c.key==air.SearchKey())
		{
			continue;
		}
		YsVec3 rel=c.pos-air.GetPosition();
		if(rel.GetSquareLength()<FSRVB_AHEAD_CLEAR*FSRVB_AHEAD_CLEAR)
		{
			air.GetAttitude().MulInverse(rel,rel);
			if(0.0<rel.z() && fabs(rel.x())<25.0)
			{
				YsVec3 back=air.GetPosition()-c.pos;  // Am I ahead of it too (nose to nose)?
				const YSBOOL mutual=(0.0<back*c.fwd ? YSTRUE : YSFALSE);
				if(YSTRUE!=mutual || c.key<air.SearchKey())
				{
					return YSTRUE;
				}
			}
		}
	}
	return YSFALSE;
}

YSBOOL FsRvbRecovery::HoldShort(const FsAirplane &air,const FsRvbTeamPicture &pic) const
{
	// One aircraft on the runway at a time: wait short of it (the leg that joins the runway) while anyone
	// else is on the strip or landing.
	const double d2=(path[nPath-1]-air.GetPosition()).GetSquareLengthXZ();
	if(YSTRUE!=rwyValid || pathIdx!=nPath-1 || d2>FSRVB_HOLD_SHORT_DIST*FSRVB_HOLD_SHORT_DIST || d2<YsSqr(25.0))
	{
		return YSFALSE;
	}
	YsVec3 dir=rwyEnd[1]-rwyEnd[0];
	dir.SetY(0.0);
	const double lng=dir.GetLength();
	dir.Normalize();
	for(auto &c : pic.air)
	{
		if(c.key==air.SearchKey())
		{
			continue;
		}
		const YsVec3 rel=c.pos-rwyEnd[0];
		const double along=rel.x()*dir.x()+rel.z()*dir.z();
		const double lat=fabs(rel.x()*dir.z()-rel.z()*dir.x());
		const YSBOOL onStrip=(-3000.0<along && along<lng+300.0 && lat<60.0 && c.pos.y()<rwyEnd[0].y()+300.0 ? YSTRUE : YSFALSE);
		if(YSTRUE==onStrip)
		{
			return YSTRUE;
		}
	}
	return YSFALSE;
}

YSBOOL FsRvbRecovery::RunwayBusy(const FsAirplane &air,const FsRvbTeamPicture &pic) const
{
	// Someone landing or rolling on this runway.
	const YsVec3 mid=(rwyEnd[0]+rwyEnd[1])/2.0;
	const double halfLng=(rwyEnd[1]-rwyEnd[0]).GetLength()/2.0;
	YsVec3 dir=rwyEnd[1]-rwyEnd[0];
	dir.SetY(0.0);
	dir.Normalize();
	for(auto &c : pic.air)
	{
		if(c.key==air.SearchKey())
		{
			continue;
		}
		const double speed=c.vel.GetLength();
		const double d=(c.pos-mid).GetLengthXZ();
		if(40.0<speed && c.pos.y()<mid.y()+300.0 && d<halfLng+2500.0)
		{
			return YSTRUE;  // Landing or rolling
		}
		// Anything sitting on the strip ahead of the start (not behind us at the start itself).
		const YsVec3 rel=c.pos-air.GetPosition();
		const double along=rel.x()*dir.x()+rel.z()*dir.z();
		const double lat=fabs(rel.x()*dir.z()-rel.z()*dir.x());
		if(YSTRUE!=c.airborne && 20.0<along && along<halfLng*2.0 && lat<40.0)
		{
			return YSTRUE;
		}
	}
	return YSFALSE;
}

YSRESULT FsRvbRecovery::MakeDecision(FsAirplane &air,FsSimulation *sim,const FsRvbTeamPicture &pic,const double dt)
{
	stageTimer+=dt;
	switch(stage)
	{
	default:
	case STAGE_IDLE:
	case STAGE_DONE:
		break;
	case STAGE_TRANSIT:
		if(FsSimInfo::CARRIER==baseType)
		{
			const FsGround *carrier=sim->FindGround(carrierKey);
			if(NULL==carrier || YSTRUE!=carrier->IsAlive())
			{
				StartRtb(air,sim,pic);  // Carrier lost: next nearest base
				return YSOK;
			}
			basePos=carrier->GetPosition();
		}
		{
			YsVec3 dest=basePos;
			dest.SetY(YsBound(air.GetPosition().y(),basePos.y()+FSRVB_TRANSIT_ALT[0],basePos.y()+FSRVB_TRANSIT_ALT[1]));
			transitAP->SetSingleDestination(dest);
			transitAP->SetSpeed(0.0);
			transitAP->SetThrottle(1.0);
			transitAP->SetUseAfterburner(YSFALSE);
			transitAP->MakeDecision(air,sim,dt);
		}
		if((basePos-air.GetPosition()).GetSquareLengthXZ()<FSRVB_APPROACH_DIST*FSRVB_APPROACH_DIST)
		{
			BeginApproach(air,sim);
		}
		break;
	case STAGE_PATTERN:
		pattern.Update(steer,air,dt);
		if(FsRvbApproach::PHASE_GATE==pattern.GetPhase())
		{
			BeginFinal(air,sim);
		}
		else if(FsRvbApproach::PHASE_FAILED==pattern.GetPhase())
		{
			++nGoAround;
			pattern.Start(air,landThreshold,landDir,(rwyEnd[1]-rwyEnd[0]).GetLength());
		}
		break;
	case STAGE_APPROACH:
		landingAP->MakeDecision(air,sim,dt);
		if(YSTRUE==air.Prop().IsOnGround())
		{
			if(NULL!=air.Prop().OnThisCarrier())
			{
				if(FsRvbGroundSpeed(air)-air.Prop().OnThisCarrier()->Prop().GetVelocity()<2.0)
				{
					++nTotalLanding;
					canRefuel=YSTRUE;
					supplyKey=carrierKey;
					SetStage(STAGE_REFUEL);
				}
			}
			else
			{
				++nTotalLanding;
				SetStage(STAGE_ROLLOUT);
			}
		}
		else if(FSRVB_APPROACH_TIMEOUT<stageTimer)
		{
			++nGoAround;
			BeginApproach(air,sim);
		}
		break;
	case STAGE_ROLLOUT:
		if(FsRvbGroundSpeed(air)<FSRVB_ROLLOUT_SPEED)
		{
			BeginTaxiToSupply(air,sim);
		}
		break;
	case STAGE_TAXI_TO_SUPPLY:
		{
			YSBOOL fuel,ammo;
			const YsVec3 &target=path[pathIdx];
			if(NULL!=sim->FindNearbySupplyTruck(fuel,ammo,air) && pathIdx==nPath-1)
			{
				SetStage(STAGE_REFUEL);
			}
			else if((target-air.GetPosition()).GetSquareLengthXZ()<YsSqr(pathIdx==nPath-1 ? 6.0 : 20.0) ||
			        YSTRUE==CirclingWaypoint(air,dt))
			{
				if(nPath-1<=pathIdx)
				{
					SetStage(STAGE_REFUEL);
				}
				else
				{
					++pathIdx;
				}
			}
		}
		break;
	case STAGE_REFUEL:
		if((YSTRUE==canRefuel ? FSRVB_REFUEL_TIME : FSRVB_REFUEL_TIME_NOSUPPLY)<=stageTimer)
		{
			air.Prop().LoadFuel();
			air.RecallReloadCommandOnly();
			++nRefuel;
			++nTotalRefuel;
			if(NULL!=air.Prop().OnThisCarrier())
			{
				ClearSubAutopilot();
				BeginCarrierLaunch(air);
			}
			else
			{
				ChooseRunway(air,pic);
				BeginTaxiToRunway(air);
			}
		}
		break;
	case STAGE_TAXI_TO_RUNWAY:
		if((path[pathIdx]-air.GetPosition()).GetSquareLengthXZ()<YsSqr(20.0) || YSTRUE==CirclingWaypoint(air,dt))
		{
			if(nPath-1<=pathIdx)
			{
				SetStage(STAGE_LINEUP);
			}
			else
			{
				++pathIdx;
			}
		}
		break;
	case STAGE_LINEUP:
		{
			const YsVec3 dir=YsUnitVector(rwyEnd[1]-rwyEnd[0]);
			if(fabs(FsRvbRelativeHeadingOnGround(air,dir))<YsDegToRad(3.0) &&
			   (YSTRUE!=RunwayBusy(air,pic) || FSRVB_HOLD_MAX<stageTimer))
			{
				BeginTakeOff(air,sim,air.GetPosition(),dir);
			}
		}
		break;
	case STAGE_CARRIER_TAXI:
		carrierTaxiAP->MakeDecision(air,sim,dt);
		if(YSTRUE==carrierTaxiAP->MissionAccomplished(air,sim) || FSRVB_CARRIER_TAXI_TIMEOUT<stageTimer)
		{
			BeginDeckLaunch(air);
		}
		break;
	case STAGE_TAKEOFF:
		takeoffAP->MakeDecision(air,sim,dt);
		if(YSTRUE==takeoffAP->MissionAccomplished(air,sim) ||
		   (YSTRUE!=air.Prop().IsOnGround() && air.GetPosition().y()>=takeoffAP->desigAlt-100.0))
		{
			++nTotalTakeoff;
			ClearSubAutopilot();
			SetStage(STAGE_DONE);
		}
		break;
	}
	return YSOK;
}

YSRESULT FsRvbRecovery::ApplyControl(FsAirplane &air,FsSimulation *sim,const double dt)
{
	switch(stage)
	{
	default:
	case STAGE_IDLE:
		if(YSTRUE==air.Prop().IsOnGround())
		{
			Hold(air);  // Parked, no runway to use
		}
		break;
	case STAGE_DONE:
		break;
	case STAGE_TRANSIT:
		transitAP->ApplyControl(air,sim,dt);
		air.Prop().TurnOffSpeedController();
		air.Prop().SetThrottle(1.0);  // Brisk: full military power home
		air.Prop().SetAfterburner(YSFALSE);
		air.Prop().SetGear(0.0);
		break;
	case STAGE_PATTERN:
		break;  // The tactical autopilot applies GetSteer()
	case STAGE_APPROACH:
		landingAP->ApplyControl(air,sim,dt);
		break;
	case STAGE_ROLLOUT:
		air.Prop().TurnOffSpeedController();
		air.Prop().SetThrottle(0.0);
		air.Prop().SetAfterburner(YSFALSE);
		air.Prop().SetBrake(1.0);
		air.Prop().SetSpoiler(1.0);
		air.Prop().SetRudder(0.0);
		break;
	case STAGE_TAXI_TO_SUPPLY:
	case STAGE_TAXI_TO_RUNWAY:
		if(YSTRUE==SomethingAhead(air,FsRvbTeamPicture::Get(sim)) ||
		   (STAGE_TAXI_TO_RUNWAY==stage && YSTRUE==HoldShort(air,FsRvbTeamPicture::Get(sim))))
		{
			holdTimer+=dt;
			Hold(air);
		}
		else
		{
			if(holdTimer<=FSRVB_HOLD_GIVEUP)
			{
				holdTimer=0.0;  // A short wait is over.  After giving up it keeps going for the rest of the stage.
			}
			Taxi(air,path[pathIdx],taxiSpeed[pathIdx],dt);
		}
		break;
	case STAGE_LINEUP:
		{
			Taxi(air,rwyEnd[1],FSRVB_LINEUP_SPEED,dt);
		}
		break;
	case STAGE_REFUEL:
		Hold(air);
		break;
	case STAGE_CARRIER_TAXI:
		carrierTaxiAP->ApplyControl(air,sim,dt);
		break;
	case STAGE_TAKEOFF:
		takeoffAP->ApplyControl(air,sim,dt);
		break;
	}
	return YSOK;
}

void FsRvbRecovery::Taxi(FsAirplane &air,const YsVec3 &to,const double speed,const double)
{
	air.Prop().NeutralDirectAttitudeControl();
	air.Prop().TurnOffController();
	air.Prop().SetElevator(0.0);
	air.Prop().SetFlap(0.0);
	air.Prop().SetSpoiler(0.0);
	air.Prop().SetGear(1.0);
	air.Prop().SetAfterburner(YSFALSE);

	YsVec3 dir=to-air.GetPosition();
	const double dist=dir.GetLengthXZ();
	dir.SetY(0.0);
	hdgErr=FsRvbRelativeHeadingOnGround(air,dir);
	air.Prop().SetRudder(YsBound(hdgErr/YsDegToRad(5.0),-1.0,1.0));

	// Nose-wheel turns are wide at speed: slow right down until the nose points at the waypoint, or the
	// aircraft ends up circling it.
	double desired=speed;
	if(fabs(hdgErr)>YsDegToRad(20.0))
	{
		desired=YsSmaller(desired,FSRVB_TAXI_TURN);
	}
	else if(fabs(hdgErr)>YsDegToRad(8.0))
	{
		desired=YsSmaller(desired,FSRVB_TAXI_TURN*2.0);
	}
	desired=YsSmaller(desired,3.0+dist*0.15);  // Slow down into the waypoint

	const double v=FsRvbGroundSpeed(air);
	if(v<desired)
	{
		air.Prop().SetBrake(0.0);
		air.Prop().SetThrottle(YsBound(0.15+(desired-v)*0.05,0.0,0.8));
	}
	else if(v>desired+1.0)
	{
		air.Prop().SetBrake(1.0);
		air.Prop().SetThrottle(0.0);
	}
	else
	{
		air.Prop().SetBrake(0.0);
		air.Prop().SetThrottle(0.1);
	}
}

void FsRvbRecovery::Hold(FsAirplane &air)
{
	air.Prop().NeutralDirectAttitudeControl();
	air.Prop().TurnOffController();
	air.Prop().SetThrottle(0.0);
	air.Prop().SetAfterburner(YSFALSE);
	air.Prop().SetBrake(1.0);
	air.Prop().SetRudder(0.0);
}
