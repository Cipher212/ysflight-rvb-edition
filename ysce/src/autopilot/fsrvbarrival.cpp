#include <ysclass.h>

#include "fs.h"
#include "fsrvbarrival.h"
#include "fsrvbtraffic.h"
#include "fsrvbflightpath.h"

// RvB: see fsrvbarrival.h (YSFlight RvB Edition, 2026-10-01).

// Safety margins against the user's numbers (user's rules, planning/AI_rebuild_plan.md): one number per phase,
// tightened towards his figures as the harness proves it safe.
static const double FSRVB_TAXI_CORNER_FACTOR=0.75;   // Taxi corners: start ~25 % slower than the user
static const double FSRVB_TAXI_STRAIGHT_FACTOR=1.0;  // Taxi straights: his speed
static const double FSRVB_TAXI_PLAN_DECEL=1.5;       // m/s^2 planned braking: brake EARLY for corners and stops
static const double FSRVB_CORNER_RADIUS=120.0;       // m: tighter than this is a full corner
static const double FSRVB_STRAIGHT_RADIUS=400.0;     // m: wider than this is a straight
static const double FSRVB_YAW_MARGIN=0.8;            // Of the nose-wheel yaw rate YS can give
static const double FSRVB_TOUCHDOWN_MIN_ALONG=10.0;  // m past the pavement start: never earlier

// Approach
static const double FSRVB_AIR_LOOKAHEAD_TIME=6.0;    // s of flight path ahead that the turn aims at
static const double FSRVB_AIR_LOOKAHEAD_MIN=400.0;
static const double FSRVB_AIR_LOOKAHEAD_MAX=1500.0;
static const double FSRVB_VERT_LEAD=4.0;             // s: height target taken this far ahead
static const double FSRVB_SPEED_LEAD=6.0;            // s: speed target taken this far ahead (slow down in time)
static const double FSRVB_VSPEED_MAX_DOWN=200.0;     // m/s: the user dives ~40 deg at 550 kt from a high entry
static const double FSRVB_PULLOUT_ACCEL=18.0;        // m/s^2 planned for the pull-out: dive no faster than this can stop
static const double FSRVB_VSPEED_MAX_UP=25.0;
static const double FSRVB_APPROACH_MAX_BANK=YsDegToRad(82.0);  // The user banks 60-86 deg joining final
static const double FSRVB_APPROACH_G_MAX=6.5;                   // The user pulls up to 6.3 G
static const double FSRVB_MIN_AGL=40.0;              // m above the terrain until short final
static const double FSRVB_SHORT_FINAL=2500.0;        // m to the touchdown: inside this the terrain floor is off
static const double FSRVB_JOIN_DIST=1500.0;          // m off the line: fly to the gate first
static const double FSRVB_RUNWAY_BOOK_DIST=3000.0;   // m to the touchdown: book the runway here
static const double FSRVB_GOAROUND_DIST=700.0;       // m to the touchdown: still this far off -> go around
static const double FSRVB_GOAROUND_HEIGHT=60.0;      // m wheels above the runway
static const double FSRVB_GOAROUND_CROSS=25.0;       // m off the centre line
static const double FSRVB_GLIDE_DIST=1500.0;         // m to the touchdown: from here never above the glide path
static const double FSRVB_GLIDE_ANGLE=YsDegToRad(3.0);  // to the user's median touchdown point
static const double FSRVB_FLARE_HEIGHT=5.0;          // m wheels above the runway (the user flies onto it, barely flaring)
static const double FSRVB_FLARE_SINK[2]={0.6,2.5};   // m/s: sink range used to put the wheels down at the touchdown aim
static const double FSRVB_FLARE_LOOKAHEAD=500.0;     // m along the centre line
static const double FSRVB_FLARE_MAX_BANK=YsDegToRad(8.0);
// Holding and orbit guidance (YSFlight RvB Edition, 2026-10-03)
static const double FSRVB_HOLD_RADIUS=2000.0;          // m: holding orbit radius
static const double FSRVB_HOLD_BASE_ALT=600.0;        // m: base holding altitude above runway
static const double FSRVB_HOLD_STACK_SEP=300.0;       // m: vertical separation per stack level
static const double FSRVB_HOLD_MAX_BANK=YsDegToRad(40.0); // max bank in orbit (gives achievable turn)
static const double FSRVB_HOLD_MAX_CORR_ANG=YsDegToRad(30.0); // max angle off tangent to correct radial error
static const double FSRVB_HOLD_LOOKAHEAD_TIME=4.0;    // s of flight path ahead on the orbit
static const double FSRVB_HOLD_ESTABLISHED_TOL=300.0; // m: radial error threshold to consider orbit established
static const double FSRVB_GOAROUND_GEAR_UP=100.0;     // m wheels above the runway: gear up in the go-around

// Re-entry and approach capture tolerances (YSFlight RvB Edition, 2026-10-03)
static const double FSRVB_CAPTURE_POS_TOL=500.0;      // m cross-track from approach course
static const double FSRVB_CAPTURE_HDG_TOL=YsDegToRad(40.0); // rad alignment with approach line heading
static const double FSRVB_CAPTURE_HEIGHT_TOL=150.0;   // m from target approach line height

// Ground
static const double FSRVB_TAXI_LOOKAHEAD_BASE=5.0;   // m (short: pure pursuit cuts corners by about the look-ahead)
static const double FSRVB_TAXI_LOOKAHEAD_TIME=0.6;   // s
static const double FSRVB_TAXI_SPEED_LEAD=0.4;       // s: speed target taken this far ahead
static const double FSRVB_ROUTE_END=2.0;             // m from the route end: arrived
static const double FSRVB_REARM_STOP_TIME=2.5;       // s stopped at the supply spot (instant AI rearm, for looks)
static const double FSRVB_REARM_ZONE_RADIUS=110.0;   // m around a rearm stop: one jet at a time (stub + spot)
static const double FSRVB_RUNWAY_CLEAR=20.0;         // m beyond the runway edge: off the runway
static const double FSRVB_HOLD_SHORT=50.0;           // m from the centre line: hold line before the runway
static const double FSRVB_DEPARTURE_ARRIVAL_GAP=6000.0;  // m: no take-off while an arrival is this close in
static const double FSRVB_STUCK_TIME=40.0;           // s without moving (not held by traffic): failed

// Take-off and climb
static const double FSRVB_LINEUP_LOOKAHEAD=25.0;     // m along the centre line
static const double FSRVB_LINEUP_SPEED=3.0;          // m/s
static const double FSRVB_LINEUP_HEADING=YsDegToRad(2.0);
static const double FSRVB_LINEUP_CROSS=2.5;          // m
static const double FSRVB_LINEUP_MAX_TIME=25.0;      // s: then go anyway
static const double FSRVB_TAKEOFF_LOOKAHEAD=40.0;    // m along the centre line, plus...
static const double FSRVB_TAKEOFF_LOOKAHEAD_TIME=1.2;// s of roll
static const double FSRVB_LIFTOFF_HEIGHT=4.0;        // m above the runway: airborne
static const double FSRVB_GEAR_UP_HEIGHT=15.0;
static const double FSRVB_FLAP_UP_HEIGHT=60.0;
static const double FSRVB_CLIMB_MAX_BANK=YsDegToRad(20.0);
static const double FSRVB_DONE_DIST=3000.0;          // m past lift-off
static const double FSRVB_DONE_HEIGHT=120.0;         // m above the runway
static const double FSRVB_CRUISE_HEIGHT=300.0;       // m above the runway after the climb-out

FsRvbArrival::Report::Report()
{
	touchedDown=YSFALSE;
	tdAlong=tdCross=tdSpeed=tdSink=tdTime=0.0;
	offPavementTime=0.0;
	offPavementPos=YsOrigin();
	rearmed=YSFALSE;
	rearmStopError=0.0;
	rearmTime=0.0;
	airborne=YSFALSE;
	liftoffAlong=liftoffSpeed=airborneTime=0.0;
	waitTime=0.0;
	goArounds=0;
	gateChanges=0;
	holdMaxDist=0.0;
	holdRadialErrMax=0.0;
	holdEstablishedRadialErrMax=0.0;
	holdOrbitDuration=0.0;
	minTerrainClearance=YsInfinity;
}

FsRvbArrival::FsRvbArrival()
{
	plan=NULL;
	phase=PHASE_APPROACH;
	phaseTimer=0.0;
	clock=0.0;
	initialized=YSFALSE;
	lineIdx=0;
	blend=0.0;
	sPath=0.0;
	gearLatched=YSFALSE;
	flapLatched=YSFALSE;
	flareBank=0.0;
	flareVSpeed=-FSRVB_FLARE_SINK[0];
	spotIdx=0;
	route=NULL;
	sRoute=0.0;
	holdLineS=0.0;
	aim=YsOrigin();
	taxiSpeed=0.0;
	holding=YSFALSE;
	stillTimer=0.0;
	liftoffClock=0.0;
	liftoffPos=YsOrigin();

	// Holding state (YSFlight RvB Edition, 2026-10-03)
	airKey=YSNULLHASHKEY;
	holdState=HOLD_NONE;
	holdLineIdx=0;
	initialHoldLineIdx=0;
	holdCenter=YsOrigin();
	holdRadius=FSRVB_HOLD_RADIUS;
	holdBaseAlt=FSRVB_HOLD_BASE_ALT;
	targetAlt=FSRVB_HOLD_BASE_ALT;
	holdSpeed=115.0;
	holdStackLevel=0;
	holdOrbitDuration=0.0;
	holdRadialErrMax=0.0;
	holdEstablishedRadialErrMax=0.0;
	holdDistMax=0.0;
	minTerrainClearance=YsInfinity;
	currentRadialError=0.0;
	gateChanges=0;
}

FsRvbArrival::~FsRvbArrival()
{
	if(NULL!=plan && YSNULLHASHKEY!=airKey)
	{
		FsRvbTraffic::ReleaseAll(airKey);
		FsRvbTraffic::LeaveHold(plan,airKey);
	}
}

/* static */ FsRvbArrival *FsRvbArrival::Create(const FsRvbAirfieldPlan *plan)
{
	FsRvbArrival *ap=new FsRvbArrival;
	ap->plan=plan;
	return ap;
}

/* static */ const char *FsRvbArrival::PhaseToStr(PHASE p)
{
	switch(p)
	{
	case PHASE_APPROACH:
		return "APPROACH";
	case PHASE_HOLDING:
		return "HOLDING";
	case PHASE_FLARE:
		return "FLARE";
	case PHASE_TAXI_IN:
		return "TAXI_IN";
	case PHASE_REARM:
		return "REARM";
	case PHASE_TAXI_OUT:
		return "TAXI_OUT";
	case PHASE_LINEUP:
		return "LINEUP";
	case PHASE_TAKEOFF:
		return "TAKEOFF";
	case PHASE_CLIMB:
		return "CLIMB";
	case PHASE_DONE:
		return "DONE";
	default:
	case PHASE_FAILED:
		return "FAILED";
	}
}

/* static */ const char *FsRvbArrival::HoldStateToStr(HOLD_STATE s)
{
	switch(s)
	{
	case HOLD_JOINING:
		return "JOINING";
	case HOLD_ORBITING:
		return "ORBITING";
	case HOLD_REJOINING:
		return "REJOINING";
	default:
	case HOLD_NONE:
		return "NONE";
	}
}

FsRvbArrival::PHASE FsRvbArrival::GetPhase(void) const
{
	return phase;
}

FsRvbArrival::HOLD_STATE FsRvbArrival::GetHoldState(void) const
{
	return holdState;
}

double FsRvbArrival::GetPhaseTime(void) const
{
	return phaseTimer;
}

const FsRvbArrival::Report &FsRvbArrival::GetReport(void) const
{
	return report;
}

const FsRvbAirfieldPlan *FsRvbArrival::GetPlan(void) const
{
	return plan;
}

const char *FsRvbArrival::GetLineName(void) const
{
	return (NULL!=plan && plan->approach.IsInRange(lineIdx) ? plan->approach[lineIdx].name.Txt() : "");
}

YSBOOL FsRvbArrival::IsHeldByTraffic(void) const
{
	return holding;
}

const YsVec3 &FsRvbArrival::GetHoldCenter(void) const
{
	return holdCenter;
}

double FsRvbArrival::GetHoldRadius(void) const
{
	return holdRadius;
}

double FsRvbArrival::GetHoldRadialError(void) const
{
	return currentRadialError;
}

double FsRvbArrival::GetMinTerrainClearance(void) const
{
	return minTerrainClearance;
}

int FsRvbArrival::GetGateChanges(void) const
{
	return gateChanges;
}

double FsRvbArrival::GetAssignedAlt(void) const
{
	return targetAlt;
}

int FsRvbArrival::GetHoldStackLevel(void) const
{
	return holdStackLevel;
}

double FsRvbArrival::GetHoldSpeed(void) const
{
	return holdSpeed;
}

double FsRvbArrival::GetHoldOrbitDuration(void) const
{
	return holdOrbitDuration;
}

double FsRvbArrival::GetEstablishedRadialErrMax(void) const
{
	return holdEstablishedRadialErrMax;
}

YSBOOL FsRvbArrival::HasClearance(const char zone[]) const
{
	if(NULL!=plan && YSNULLHASHKEY!=airKey)
	{
		return FsRvbTraffic::HasClearance(plan,zone,airKey);
	}
	return YSFALSE;
}

const FsRvbPath *FsRvbArrival::GetRoute(void) const
{
	return (PHASE_TAXI_IN==phase || PHASE_TAXI_OUT==phase ? route : NULL);
}

double FsRvbArrival::GetRouteProgress(void) const
{
	return sRoute;
}

/* virtual */ YSBOOL FsRvbArrival::IsTakingOff(void) const
{
	return (PHASE_TAXI_OUT==phase || PHASE_LINEUP==phase || PHASE_TAKEOFF==phase ? YSTRUE : YSFALSE);
}

/* virtual */ YSBOOL FsRvbArrival::IsLanding(void)
{
	return (PHASE_APPROACH==phase || PHASE_FLARE==phase || PHASE_TAXI_IN==phase ? YSTRUE : YSFALSE);
}

/* virtual */ YSRESULT FsRvbArrival::MakePriorityDecision(FsAirplane &)
{
	// No YS stall / low-altitude recovery: landing is low and slow on purpose, and only the hands fly.
	emr=EMR_NONE;
	return YSOK;
}

/* virtual */ YSRESULT FsRvbArrival::SaveIntention(FILE *,const FsSimulation *)
{
	return YSOK;
}

void FsRvbArrival::SetPhase(PHASE p)
{
	phase=p;
	phaseTimer=0.0;
	stillTimer=0.0;
}

void FsRvbArrival::Fail(const char reason[])
{
	if(PHASE_FAILED!=phase)
	{
		report.failReason.Set(reason);
		if(NULL!=plan && YSNULLHASHKEY!=airKey)
		{
			FsRvbTraffic::ReleaseAll(airKey);
			FsRvbTraffic::LeaveHold(plan,airKey);
		}
		SetPhase(PHASE_FAILED);
	}
}

double FsRvbArrival::RunwayElevation(FsSimulation *sim) const
{
	const YsVec3 td=plan->OnCentreLine(plan->tdMedian);
	return sim->GetFieldElevation(td.x(),td.z());
}

void FsRvbArrival::ChooseLine(const FsAirplane &air)
{
	// The line whose gate lies in the direction the aircraft comes from; blend by its height against the user's
	// low and high runs at that gate.
	const YsVec3 td=plan->OnCentreLine(plan->tdMedian);
	YsVec3 me=air.GetPosition()-td;
	me.SetY(0.0);
	me.Normalize();
	double best=-YsInfinity;
	for(int i=0; i<plan->approach.GetN(); ++i)
	{
		const YsVec2 g=plan->approach[i].path.PointAt(0.0);
		YsVec3 toGate(g.x()-td.x(),0.0,g.y()-td.z());
		toGate.Normalize();
		if(best<me*toGate)
		{
			best=me*toGate;
			lineIdx=i;
		}
	}
	const FsRvbApproachLine &line=plan->approach[lineIdx];
	const double lo=line.y[0][0],hi=line.y[1][0];
	blend=(YsTolerance<fabs(hi-lo) ? YsBound((air.GetPosition().y()-lo)/(hi-lo),0.0,1.0) : 0.0);
	sPath=line.path.Project(air.GetPosition(),0.0,line.path.Length());
}

void FsRvbArrival::Start(FsAirplane &air,FsSimulation *sim)
{
	initialized=YSTRUE;
	airKey=air.SearchKey();
	hands.Reset(air);
	if(0==air.GetReloadCommand().GetN())
	{
		// The rearm stop reloads with YS RecallReloadCommandOnly: missions without RELDCMND lines get the
		// loadout the aircraft was set up with.
		for(auto &cmd : air.cmdLog)
		{
			if(0==strncmp(cmd,"UNLOADWP",8) || 0==strncmp(cmd,"LOADWEPN",8) || 0==strncmp(cmd,"INITIGUN",8))
			{
				air.AddReloadCommand(cmd);
			}
		}
	}
	if(YSTRUE==air.Prop().IsOnGround())
	{
		// Parked: straight to the nearest rearm spot's way out (the test can start a jet on the ground too).
		double bestD2=YsInfinity;
		for(int i=0; i<plan->rearm.GetN(); ++i)
		{
			const double d2=(plan->rearm[i].stopPos-air.GetPosition()).GetSquareLengthXZ();
			if(d2<bestD2)
			{
				bestD2=d2;
				spotIdx=i;
			}
		}
		BeginRoute(plan->rearm[spotIdx].out,air,YSTRUE);
		SetPhase(PHASE_TAXI_OUT);
		return;
	}
	ChooseLine(air);
	gearLatched=YSFALSE;
	flapLatched=YSFALSE;
	SetPhase(PHASE_APPROACH);
	(void)sim;
}

YsString FsRvbArrival::RearmZone(const int spot) const
{
	YsString zone("REARM:");
	zone.Append(plan->rearm[spot].name);
	return zone;
}

void FsRvbArrival::BeginRoute(const FsRvbPath &path,FsAirplane &air,const YSBOOL wayOut)
{
	route=&path;
	sRoute=path.Project(air.GetPosition(),0.0,YsSmaller(path.Length(),200.0));
	routeSpeed.Clear();  // Planned on the first tick on the ground (the nose-wheel yaw rate is known then)

	// Hold line.  Way in: where the route enters the rearm spot's zone.  Way out: where the route's final run
	// onto the runway starts (the last point still clear of it).
	holdLineS=0.0;
	if(YSTRUE!=wayOut)
	{
		const YsVec3 &stop=plan->rearm[spotIdx].stopPos;
		for(int i=0; i<path.GetN(); ++i)
		{
			if((path.p[i]-YsVec2(stop.x(),stop.z())).GetLength()<FSRVB_REARM_ZONE_RADIUS)
			{
				holdLineS=YsGreater(0.0,path.s[i]-5.0);
				break;
			}
		}
	}
	else
	{
		for(int i=path.GetN()-1; 0<=i; --i)
		{
			const YsVec3 q(path.p[i].x(),0.0,path.p[i].y());
			if(fabs(plan->Cross(q))>FSRVB_HOLD_SHORT)
			{
				holdLineS=path.s[i];
				break;
			}
		}
	}
}

void FsRvbArrival::PlanRouteSpeed(FsAirplane &air)
{
	// The user's speed per point with the margins, capped by what the nose wheel can turn, then a backward
	// pass so the AI brakes early (gently) for every corner and for the stop at the end.
	const FsRvbPath &r=*route;
	const int n=r.GetN();
	routeSpeed.Set(n,NULL);
	const double yawMax=YsGreater(0.2,fabs(air.Prop().GetGroundYawSpeed(1.0)))*FSRVB_YAW_MARGIN;
	for(int i=0; i<n; ++i)
	{
		const double k=r.CurvatureAt(r.s[i],12.0);
		const double t=YsBound((k-1.0/FSRVB_STRAIGHT_RADIUS)/(1.0/FSRVB_CORNER_RADIUS-1.0/FSRVB_STRAIGHT_RADIUS),0.0,1.0);
		const double factor=FSRVB_TAXI_STRAIGHT_FACTOR*(1.0-t)+FSRVB_TAXI_CORNER_FACTOR*t;
		double v=r.v[i]*factor;
		if(YsTolerance<k)
		{
			v=YsSmaller(v,yawMax/k);
		}
		routeSpeed[i]=v;
	}
	routeSpeed[n-1]=0.0;  // Every route ends with a stop (rearm spot, or the take-off roll start)
	for(int i=n-2; 0<=i; --i)
	{
		const double ds=r.s[i+1]-r.s[i];
		routeSpeed[i]=YsSmaller(routeSpeed[i],sqrt(routeSpeed[i+1]*routeSpeed[i+1]+2.0*FSRVB_TAXI_PLAN_DECEL*ds));
	}
}

/* virtual */ YSRESULT FsRvbArrival::MakeDecision(FsAirplane &air,FsSimulation *sim,const double &dt)
{
	if(NULL==plan || 0==plan->approach.GetN() || 0==plan->rearm.GetN())
	{
		return YSERR;
	}
	if(YSTRUE!=initialized)
	{
		Start(air,sim);
	}
	clock+=dt;
	phaseTimer+=dt;
	holding=YSFALSE;
	FsRvbTraffic::PurgeDead(sim);

	if(YSTRUE==air.Prop().IsOnGround() && YSTRUE==air.Prop().IsOutOfRunway())
	{
		if(0.0==report.offPavementTime)
		{
			report.offPavementPos=air.GetPosition();
		}
		report.offPavementTime+=dt;
	}

	switch(phase)
	{
	case PHASE_APPROACH:
	case PHASE_HOLDING:
		DecideApproach(air,sim,dt);
		break;
	case PHASE_FLARE:
		DecideFlare(air,sim);
		break;
	case PHASE_TAXI_IN:
	case PHASE_TAXI_OUT:
		DecideTaxi(air,sim,dt);
		break;
	case PHASE_REARM:
		DecideRearm(air,sim);
		break;
	case PHASE_LINEUP:
		DecideLineUp(air);
		break;
	case PHASE_TAKEOFF:
		DecideTakeOff(air,sim);
		break;
	case PHASE_CLIMB:
	case PHASE_DONE:
		DecideClimb(air,sim);
		break;
	default:
		break;
	}
	if(YSTRUE==holding)
	{
		report.waitTime+=dt;
	}
	return YSOK;
}

// Highest ground under the flight path now and over the next few seconds
static double FsRvbTerrainAhead(const FsAirplane &air,FsSimulation *sim)
{
	YsVec3 vel;
	air.Prop().GetVelocity(vel);
	vel.SetY(0.0);
	double top=-YsInfinity;
	for(double t : {0.0,2.0,4.0,6.0,8.0})
	{
		const YsVec3 q=air.GetPosition()+vel*t;
		top=YsGreater(top,sim->GetFieldElevation(q.x(),q.z()));
	}
	return top;
}

// Terrain prediction follows the bank command and the current roll, not a maximum-rate
// chase toward aim. YSFlight RvB Edition, 2026-10-03.
static FsRvbFlightPath::Input FsRvbFlightPathInput(const FsAirplane &air,const YsVec3 &aim,const double maxBank)
{
	YsVec3 vel;
	air.Prop().GetVelocity(vel);
	vel.SetY(0.0);
	double speed=vel.GetLength();
	if(speed<1.0)
	{
		vel=air.GetAttitude().GetForwardVector();
		vel.SetY(0.0);
		speed=1.0;
	}
	const YsVec3 &pos=air.GetPosition();
	FsRvbFlightPath::Input in;
	in.x=pos.x();
	in.z=pos.z();
	in.speed=speed;
	in.heading=atan2(-vel.x(),vel.z());
	in.bank=air.GetAttitude().b();
	in.targetBank=FsRvbHands::BankToward(air,aim,maxBank);
	in.maxBank=maxBank;
	in.rollRate=FsRvbHands::BankRateLimit();
	in.gravity=FsGravityConst;
	in.clearance=FSRVB_MIN_AGL;
	in.lookTime=8.0;
	return in;
}

static double FsRvbFlightPathTerrainFloor(const FsAirplane &air,FsSimulation *sim,const YsVec3 &aim,const double lookTime,const double maxBank)
{
	FsRvbFlightPath::Input in=FsRvbFlightPathInput(air,aim,maxBank);
	in.lookTime=lookTime;
	return FsRvbFlightPath::TerrainFloor(in,[sim](double x,double z){return sim->GetFieldElevation(x,z);});
}

// YSFlight RvB Edition, 2026-10-03: derive coordinated holding radius and speed dynamically
void FsRvbArrival::SelectHoldingParameters(const FsAirplane &air,double &outRadius,double &outSpeed) const
{
	const double vLand=air.Prop().GetEstimatedLandingSpeed();
	const double vMan=air.Prop().GetFullyManeuvableSpeed();

	// Safe target holding speed: comfortably above landing/stall speed
	const double vTarget=(vMan>10.0 ? vMan*1.05 : (vLand>10.0 ? vLand*1.4 : 115.0));
	const double vMin=(vLand>10.0 ? vLand*1.25 : 80.0);
	const double vNominal=YsGreater(vTarget,vMin);

	// Coordinated turn requirements: v^2 / (g * R) = tan(bank).
	// Nominal holding bank is 35 deg, leaving 5 deg authority for radial error corrections up to 40 deg limit.
	const double nomBank=YsDegToRad(35.0);
	const double reqRadius=YsSqr(vNominal)/(FsGravityConst*tan(nomBank));

	// If nominal radius (2000m) is sufficient for a coordinated turn at <= 35 deg bank, use it;
	// otherwise expand radius dynamically with 15% turning margin so intervals are never inverted.
	if(reqRadius<=FSRVB_HOLD_RADIUS)
	{
		outRadius=FSRVB_HOLD_RADIUS;
		const double vCoordMax=sqrt(FsGravityConst*outRadius*tan(FSRVB_HOLD_MAX_BANK));
		outSpeed=YsBound(vNominal,vMin,vCoordMax);
	}
	else
	{
		outRadius=reqRadius*1.15;
		outSpeed=vNominal;
	}
}

// YSFlight RvB Edition, 2026-10-03: enter holding with latched geometry and altitude stacking
void FsRvbArrival::EnterHolding(FsAirplane &air,FsSimulation *sim)
{
	if(PHASE_HOLDING==phase)
	{
		return;
	}
	SetPhase(PHASE_HOLDING);
	holdState=HOLD_JOINING;
	holdOrbitDuration=0.0;
	holdRadialErrMax=0.0;
	holdEstablishedRadialErrMax=0.0;
	currentRadialError=0.0;
	holding=YSTRUE;
	gateChanges=0;

	// Stack level assignment: FIFO queue (0 = next to land)
	airKey=air.SearchKey();
	holdStackLevel=FsRvbTraffic::JoinHold(plan,airKey);

	// Select achievable holding radius and speed for this aircraft (Requirement 2 & Issue 5)
	SelectHoldingParameters(air,holdRadius,holdSpeed);

	// Select re-entry approach line and holding center ONCE upon entering hold (Requirement 1)
	const YsVec3 &pos=air.GetPosition();
	double bestD2=YsInfinity;
	int bestIdx=lineIdx;
	for(int i=0; i<plan->approach.GetN(); ++i)
	{
		const YsVec2 g=plan->approach[i].path.PointAt(0.0);
		const double d2=YsSqr(g.x()-pos.x())+YsSqr(g.y()-pos.z());
		if(d2<bestD2)
		{
			bestD2=d2;
			bestIdx=i;
		}
	}
	holdLineIdx=bestIdx;
	initialHoldLineIdx=holdLineIdx;
	lineIdx=holdLineIdx; // Latch!
	const FsRvbApproachLine &gateLine=plan->approach[holdLineIdx];
	const YsVec2 g=gateLine.path.PointAt(0.0);
	holdCenter.Set(g.x(),0.0,g.y());

	// Check terrain clearance around the entire orbit circle, center, and entry (Requirement 7)
	const double rwyY=RunwayElevation(sim);
	double maxTerrain=-YsInfinity;
	for(int i=0; i<16; ++i)
	{
		const double ang=2.0*YsPi*(double)i/16.0;
		const double qx=holdCenter.x()+holdRadius*sin(ang);
		const double qz=holdCenter.z()+holdRadius*cos(ang);
		maxTerrain=YsGreater(maxTerrain,sim->GetFieldElevation(qx,qz));
	}
	maxTerrain=YsGreater(maxTerrain,sim->GetFieldElevation(holdCenter.x(),holdCenter.z()));
	maxTerrain=YsGreater(maxTerrain,sim->GetFieldElevation(pos.x(),pos.z()));
	const double safeAlt=maxTerrain+FSRVB_MIN_AGL*2.5;

	// Terrain-safe base altitude (stack level 0) in MSL
	holdBaseAlt=YsGreater(rwyY+FSRVB_HOLD_BASE_ALT,safeAlt);
	// Current assigned altitude in MSL applies stack offset exactly once (Issue 1)
	targetAlt=holdBaseAlt+(double)holdStackLevel*FSRVB_HOLD_STACK_SEP;
}

// YSFlight RvB Edition, 2026-10-03: orbit guidance with radial error correction and predictable capture
void FsRvbArrival::DecideHolding(FsAirplane &air,FsSimulation *sim,const double dt)
{
	const YsVec3 &pos=air.GetPosition();
	const double v=air.Prop().GetVelocity();
	const double rwyY=RunwayElevation(sim);
	holding=YSTRUE;
	airKey=air.SearchKey();

	// Prompt cleanup of dead/missing participants (Issue 2)
	FsRvbTraffic::PurgeDead(sim);

	// Validation telemetry
	const double distFromThr=(pos-plan->threshold).GetLengthXZ();
	holdDistMax=YsGreater(holdDistMax,distFromThr);
	report.holdMaxDist=holdDistMax;

	// Actual AGL terrain clearance
	const double agl=pos.y()-sim->GetFieldElevation(pos.x(),pos.z());
	minTerrainClearance=YsSmaller(minTerrainClearance,agl);
	report.minTerrainClearance=minTerrainClearance;

	// Dynamic stack level update (steps down when lower aircraft depart or die)
	holdStackLevel=FsRvbTraffic::GetHoldStackLevel(plan,airKey);
	if(holdStackLevel<0)
	{
		holdStackLevel=FsRvbTraffic::JoinHold(plan,airKey);
	}
	// Target altitude MSL applies current stack offset exactly once (Issue 1)
	targetAlt=holdBaseAlt+(double)holdStackLevel*FSRVB_HOLD_STACK_SEP;

	// Track gate changes against latched geometry (Issue 4)
	if(holdLineIdx!=initialHoldLineIdx || lineIdx!=initialHoldLineIdx)
	{
		++gateChanges;
	}
	report.gateChanges=gateChanges;

	// Vector from holding center to aircraft
	YsVec3 out=pos-holdCenter;
	out.SetY(0.0);
	const double dist=out.GetLength();
	if(YSOK!=out.Normalize())
	{
		out=YsXVec();
	}

	const double radialError=dist-holdRadius;
	currentRadialError=radialError;

	const FsRvbApproachLine &gateLine=plan->approach[holdLineIdx];
	const YsVec2 g=gateLine.path.PointAt(0.0);

	if(HOLD_JOINING==holdState)
	{
		// Travel to holding pattern (Requirement 3)
		if(dist>holdRadius*1.5)
		{
			aim=holdCenter;
		}
		else if(dist>holdRadius+FSRVB_HOLD_ESTABLISHED_TOL)
		{
			YsVec3 tangent(out.z(),0.0,-out.x()); // Clockwise tangent
			aim=holdCenter+tangent*holdRadius;
		}
		else
		{
			holdState=HOLD_ORBITING;
			holdOrbitDuration=0.0;
		}
	}

	if(HOLD_ORBITING==holdState)
	{
		holdOrbitDuration+=dt;
		report.holdOrbitDuration=holdOrbitDuration;

		holdRadialErrMax=YsGreater(holdRadialErrMax,fabs(radialError));
		report.holdRadialErrMax=holdRadialErrMax;

		// Track established orbit radial error only when established (Issue 4)
		holdEstablishedRadialErrMax=YsGreater(holdEstablishedRadialErrMax,fabs(radialError));
		report.holdEstablishedRadialErrMax=holdEstablishedRadialErrMax;

		// Clockwise tangential vector: (out.z, 0, -out.x)
		YsVec3 tangent(out.z(),0.0,-out.x());

		// Radial-error correction: turn inward if outside circle, outward if inside
		const double corrAng=YsBound(-radialError/(holdRadius*0.5),-FSRVB_HOLD_MAX_CORR_ANG,FSRVB_HOLD_MAX_CORR_ANG);
		tangent.RotateXZ(corrAng);

		const double lookDist=YsBound(v*FSRVB_HOLD_LOOKAHEAD_TIME,400.0,1000.0);
		aim=pos+tangent*lookDist;

		// Departure check (Requirement 4 & 5): lowest in stack, approach and runway free
		if(0==holdStackLevel &&
		   YSTRUE==FsRvbTraffic::IsFree(plan,"RUNWAY",airKey) &&
		   YSTRUE==FsRvbTraffic::IsFree(plan,"APPROACH",airKey))
		{
			const YsVec3 toGate=YsVec3(g.x(),0.0,g.y())-pos;
			const double distToGate=toGate.GetLengthXZ();
			if(distToGate<holdRadius*2.5)
			{
				holdState=HOLD_REJOINING;
				FsRvbTraffic::Book(plan,"APPROACH",airKey);
			}
		}
	}

	double predictedFloor=-YsInfinity;
	if(HOLD_REJOINING==holdState)
	{
		const double len=gateLine.path.Length();
		const YsVec2 dir0=gateLine.path.DirAt(0.0);

		// Along-course and cross-course relative to gate
		const YsVec2 toAir(pos.x()-g.x(),pos.z()-g.y());
		const double sAlong=toAir.x()*dir0.x()+toAir.y()*dir0.y();
		const YsVec2 onCourse=g+dir0*sAlong;
		const double crossDist=(YsVec2(pos.x(),pos.z())-onCourse).GetLength();

		// Target aim point: intercept the course at or near the gate
		double sAim=0.0;
		if(sAlong<-200.0)
		{
			// Upstream of gate: lead toward gate, clamped near gate
			sAim=YsBound(sAlong+1200.0,-1000.0,400.0);
		}
		else
		{
			// Near or past gate: look ahead along the approach line
			sAim=YsBound(sAlong+1200.0,0.0,len);
		}

		YsVec2 a;
		if(sAim<0.0)
		{
			a=g+dir0*sAim;
		}
		else
		{
			a=gateLine.path.PointAt(sAim);
		}
		aim.Set(a.x(),0.0,a.y());

		// Named tolerance validations (Requirement 4):
		// 1. Heading alignment with approach course
		YsVec3 vel;
		air.Prop().GetVelocity(vel);
		vel.SetY(0.0);
		const double trackH=atan2(-vel.x(),vel.z());
		const YsVec2 tgtDir=(sAlong<0.0 ? dir0 : gateLine.path.DirAt(YsBound(sAlong,0.0,len)));
		const double lineHdg=atan2(-tgtDir.x(),tgtDir.y());
		const double hdgDiff=fabs(atan2(sin(trackH-lineHdg),cos(trackH-lineHdg)));

		// 2. Position: cross-track within tolerance, along-track before short final
		const bool posOk=(crossDist<FSRVB_CAPTURE_POS_TOL && sAlong>=-500.0 && sAlong<=len-FSRVB_SHORT_FINAL);

		// 3. Height: within tolerance of assigned altitude (stable altitude) and clear of terrain
		const double hDiff=fabs(pos.y()-targetAlt);
		predictedFloor=FsRvbFlightPathTerrainFloor(air,sim,aim,8.0,FSRVB_APPROACH_MAX_BANK);
		const double floorY=predictedFloor;
		const bool heightOk=(hDiff<FSRVB_CAPTURE_HEIGHT_TOL && pos.y()>=floorY);

		// 4. Speed: within safe approach speed window
		const double vLand=air.Prop().GetEstimatedLandingSpeed();
		const double vSafeMin=(vLand>10.0 ? vLand*1.15 : 75.0);
		const bool spdOk=(v>=vSafeMin && v<=230.0);

		// Capture check with named tolerances (Requirement 4)
		if(posOk &&
		   hdgDiff<FSRVB_CAPTURE_HDG_TOL &&
		   heightOk &&
		   spdOk)
		{
			FsRvbTraffic::LeaveHold(plan,airKey);
			lineIdx=holdLineIdx;
			const double lo=gateLine.y[0][0],hi=gateLine.y[1][0];
			blend=(YsTolerance<fabs(hi-lo) ? YsBound((pos.y()-lo)/(hi-lo),0.0,1.0) : 0.0);
			sPath=YsBound(sAlong,0.0,len);
			holdState=HOLD_NONE;
			SetPhase(PHASE_APPROACH);
			return;
		}

		intent.speed=holdSpeed;
		intent.bank=FsRvbHands::BankToward(air,aim,FSRVB_APPROACH_MAX_BANK);
	}
	else
	{
		intent.speed=holdSpeed;
		intent.bank=FsRvbHands::BankToward(air,aim,FSRVB_HOLD_MAX_BANK);
	}

	// Flight-path terrain clearance protection (Issue 1 & 3):
	// Sample terrain along commanded flight path over bounded lookahead (curves toward aim).
	const double maxBank=(HOLD_REJOINING==holdState ? FSRVB_APPROACH_MAX_BANK : FSRVB_HOLD_MAX_BANK);
	const double floorAhead=(-YsInfinity<predictedFloor ? predictedFloor : FsRvbFlightPathTerrainFloor(air,sim,aim,8.0,maxBank));
	// Prevent stack descent from commanding below safe terrain floor ahead
	const double safeTargetAlt=YsGreater(targetAlt,floorAhead);

	const double climbReq=(floorAhead-pos.y())/4.0;
	if(climbReq>FSRVB_VSPEED_MAX_UP)
	{
		// Terrain escape (Issue 1): climbing alone cannot clear terrain ahead in time.
		// Command maximum climb rate AND initiate an immediate escape turn toward the lower flank.
		intent.vSpeed=FSRVB_VSPEED_MAX_UP;

		const FsRvbFlightPath::Input in=FsRvbFlightPathInput(air,aim,maxBank);
		intent.bank=FsRvbFlightPath::EscapeBank(in,[sim](double x,double z){return sim->GetFieldElevation(x,z);});
	}
	else if(pos.y()<floorAhead)
	{
		// Fallback emergency climb if below terrain floor
		intent.vSpeed=YsBound(climbReq,5.0,FSRVB_VSPEED_MAX_UP);
	}
	else
	{
		const double maxSink=(HOLD_REJOINING==holdState ? -15.0 : -20.0);
		intent.vSpeed=YsBound((safeTargetAlt-pos.y())/FSRVB_VERT_LEAD,maxSink,FSRVB_VSPEED_MAX_UP);
	}

	const double wheels=pos.y()-rwyY-air.Prop().GetGroundStandingHeight();
	intent.gMax=4.0;
	intent.gMin=0.0;
	intent.spoiler=YSFALSE;
	intent.spoilerForSpeed=YSTRUE;
	intent.idle=YSFALSE;
	intent.gear=(wheels<FSRVB_GOAROUND_GEAR_UP && 0.5<intent.gear ? 1.0 : 0.0);
	intent.flap=intent.gear;
}

void FsRvbArrival::DecideApproach(FsAirplane &air,FsSimulation *sim,const double dt)
{
	const FsRvbApproachLine &line=plan->approach[lineIdx];
	const double len=line.path.Length();
	const YsVec3 &pos=air.GetPosition();
	const double v=air.Prop().GetVelocity();
	const double rwyY=RunwayElevation(sim);

	if(PHASE_HOLDING==phase)
	{
		DecideHolding(air,sim,dt);
		return;
	}

	// Progress along the line: searched near the last value so the line's own turns cannot confuse it
	// Far off the line (joining at the gate, or back from holding) the progress does not move: the projection
	// would run ahead along the line and the height target with it.
	const double sNew=YsSmaller(line.path.Project(pos,sPath-200.0,sPath+800.0+v*dt),sPath+v*dt*1.5+1.0);
	if((YsVec2(pos.x(),pos.z())-line.path.PointAt(sNew)).GetLength()<FSRVB_JOIN_DIST)
	{
		sPath=sNew;
	}
	const YsVec2 onLine=line.path.PointAt(sPath);
	const double off=(YsVec2(pos.x(),pos.z())-onLine).GetLength();
	const double remain=len-sPath;

	if(remain<FSRVB_RUNWAY_BOOK_DIST && YSTRUE!=FsRvbTraffic::Book(plan,"RUNWAY",air.SearchKey()))
	{
		EnterHolding(air,sim);
		return;
	}

	// Lateral: aim ahead on the line; past its end, along the runway centre line
	const double look=YsBound(v*FSRVB_AIR_LOOKAHEAD_TIME,FSRVB_AIR_LOOKAHEAD_MIN,FSRVB_AIR_LOOKAHEAD_MAX);
	if(FSRVB_JOIN_DIST<off)
	{
		aim.Set(onLine.x(),0.0,onLine.y());  // Still on the way to the line
	}
	else if(sPath+look<=len)
	{
		const YsVec2 a=line.path.PointAt(sPath+look);
		aim.Set(a.x(),0.0,a.y());
	}
	else
	{
		aim=plan->OnCentreLine(plan->tdMedian+(sPath+look-len));
	}
	intent.bank=FsRvbHands::BankToward(air,aim,FSRVB_APPROACH_MAX_BANK);

	// Vertical: the user's height a little ahead; terrain floor until short final
	double yWant=line.HeightAt(sPath+v*FSRVB_VERT_LEAD,blend);
	if(FSRVB_JOIN_DIST<off)
	{
		yWant=YsGreater(yWant,pos.y());  // Still on the way to the gate: no descent until on the line
	}
	if(len-sPath<FSRVB_GLIDE_DIST)
	{
		// Close in: not above a glide path to the touchdown point (a high crossing floats long)
		const double toTd=YsGreater(0.0,plan->tdMedian-plan->Along(pos)-v*FSRVB_VERT_LEAD);
		yWant=YsSmaller(yWant,rwyY+air.Prop().GetGroundStandingHeight()+toTd*tan(FSRVB_GLIDE_ANGLE));
	}
	const double above=YsGreater(0.0,pos.y()-yWant);
	double downMax=YsSmaller(FSRVB_VSPEED_MAX_DOWN,sqrt(2.0*FSRVB_PULLOUT_ACCEL*above)+2.0);
	if(FSRVB_SHORT_FINAL<remain)
	{
		// Never dive faster than the pull-out above the terrain floor allows
		const double aboveFloor=YsGreater(0.0,pos.y()-FsRvbTerrainAhead(air,sim)-FSRVB_MIN_AGL);
		downMax=YsSmaller(downMax,sqrt(2.0*FSRVB_PULLOUT_ACCEL*aboveFloor));
	}
	double vs=YsBound((yWant-pos.y())/FSRVB_VERT_LEAD,-downMax,FSRVB_VSPEED_MAX_UP);
	if(FSRVB_SHORT_FINAL<remain)
	{
		const double floorY=FsRvbTerrainAhead(air,sim)+FSRVB_MIN_AGL;
		YsVec3 vel;
		air.Prop().GetVelocity(vel);
		const double sinkNow=YsGreater(0.0,-vel.y());
		const double stopDist=sinkNow*sinkNow/(2.0*FSRVB_PULLOUT_ACCEL*0.6);  // pull-out distance with a margin
		if(pos.y()<floorY+20.0+stopDist)
		{
			vs=YsGreater(vs,YsGreater(5.0,(floorY-pos.y())/2.0));  // Pull up now (the G limit makes it a full pull)
		}
	}
	intent.vSpeed=vs;
	intent.speed=line.SpeedAt(sPath+v*FSRVB_SPEED_LEAD,blend);
	intent.gMax=FSRVB_APPROACH_G_MAX;
	intent.gMin=-1.0;
	intent.afterburner=YSFALSE;
	intent.idle=YSFALSE;

	// Gear, flaps where the user put them out (they stay out); spoilers where he used them on short final,
	// and whenever well over the speed
	const unsigned cfg=line.ConfigAt(sPath,blend);
	gearLatched=(YSTRUE==gearLatched || 0!=(cfg&FsRvbApproachLine::CFG_GEAR) ? YSTRUE : YSFALSE);
	flapLatched=(YSTRUE==flapLatched || 0!=(cfg&FsRvbApproachLine::CFG_FLAP) ? YSTRUE : YSFALSE);
	intent.gear=(YSTRUE==gearLatched ? 1.0 : 0.0);
	intent.flap=(YSTRUE==flapLatched ? 1.0 : 0.0);
	intent.spoiler=(remain<FSRVB_SHORT_FINAL && 0!=(cfg&FsRvbApproachLine::CFG_SPOILER) && v>intent.speed-5.0 ? YSTRUE : YSFALSE);
	intent.spoilerForSpeed=YSTRUE;

	// Go around: still high or off the centre line close in.  Back to the holding orbit, then the line again.
	const double wheels=pos.y()-rwyY-air.Prop().GetGroundStandingHeight();
	if(remain<FSRVB_GOAROUND_DIST && (wheels>FSRVB_GOAROUND_HEIGHT || fabs(plan->Cross(pos))>FSRVB_GOAROUND_CROSS))
	{
		++report.goArounds;
		FsRvbTraffic::Release(plan,"RUNWAY",air.SearchKey());
		gearLatched=YSFALSE;
		flapLatched=YSFALSE;
		EnterHolding(air,sim);
		return;
	}

	// Flare: wheels low over the runway on short final
	if(remain<FSRVB_SHORT_FINAL && wheels<FSRVB_FLARE_HEIGHT)
	{
		intent.gear=1.0;
		SetPhase(PHASE_FLARE);
	}
}

void FsRvbArrival::DecideFlare(FsAirplane &air,FsSimulation *sim)
{
	const YsVec3 &pos=air.GetPosition();
	const double along=plan->Along(pos);
	aim=plan->OnCentreLine(along+FSRVB_FLARE_LOOKAHEAD);
	flareBank=FsRvbHands::BankToward(air,aim,FSRVB_FLARE_MAX_BANK);
	// The sink that puts the wheels down at the user's median touchdown point; never before the pavement
	const double wheels=pos.y()-RunwayElevation(sim)-air.Prop().GetGroundStandingHeight();
	const double toAim=plan->tdMedian-along;
	const double v=YsGreater(10.0,FsRvbHands::GroundSpeed(air));
	double sink=(1.0<toAim ? wheels*v/toAim : FSRVB_FLARE_SINK[1]);
	sink=YsBound(sink,FSRVB_FLARE_SINK[0],FSRVB_FLARE_SINK[1]);
	if(along+v*wheels/sink<FSRVB_TOUCHDOWN_MIN_ALONG)
	{
		sink=0.0;  // Would touch before the pavement: hold the height
	}
	flareVSpeed=-sink;
	if(YSTRUE==air.Prop().IsOnGround())
	{
		YsVec3 vel;
		air.Prop().GetVelocity(vel);
		report.touchedDown=YSTRUE;
		report.tdAlong=along;
		report.tdCross=plan->Cross(pos);
		report.tdSpeed=FsRvbHands::GroundSpeed(air);
		report.tdSink=-(pos.y()-air.prevPos.y())/YsGreater(1e-3,air.prevDt);
		report.tdTime=clock;
		FsRvbTraffic::Release(plan,"APPROACH",air.SearchKey());

		// Rearm spot: a free one, the least used first (the user varies his spots too)
		int best=-1;
		for(int i=0; i<plan->rearm.GetN(); ++i)
		{
			const YsString zone=RearmZone(i);
			if(YSTRUE==FsRvbTraffic::IsFree(plan,zone,air.SearchKey()) &&
			   (0>best || FsRvbTraffic::Uses(plan,zone)<FsRvbTraffic::Uses(plan,RearmZone(best))))
			{
				best=i;
			}
		}
		spotIdx=(0<=best ? best : (int)(air.SearchKey()%plan->rearm.GetN()));
		BeginRoute(plan->rearm[spotIdx].in,air,YSFALSE);
		SetPhase(PHASE_TAXI_IN);
	}
}

void FsRvbArrival::DecideTaxi(FsAirplane &air,FsSimulation *sim,const double dt)
{
	const FsRvbPath &r=*route;
	if(0==routeSpeed.GetN())
	{
		PlanRouteSpeed(air);
	}
	const YsVec3 &pos=air.GetPosition();
	const double v=FsRvbHands::GroundSpeed(air);
	sRoute=r.Project(pos,sRoute-5.0,sRoute+40.0+v*dt);
	const double look=FSRVB_TAXI_LOOKAHEAD_BASE+FSRVB_TAXI_LOOKAHEAD_TIME*v;
	const YsVec2 a=r.PointAt(YsSmaller(sRoute+look,r.Length()+look*0.5));
	aim.Set(a.x(),0.0,a.y());

	// Planned speed a moment ahead (the plan already brakes early)
	const double sLead=sRoute+v*FSRVB_TAXI_SPEED_LEAD;
	const int i=r.IndexAt(sLead);
	const double t=YsBound((sLead-r.s[i])/YsGreater(YsTolerance,r.s[i+1]-r.s[i]),0.0,1.0);
	double want=routeSpeed[i]*(1.0-t)+routeSpeed[i+1]*t;
	const double toEnd=r.Length()-sRoute;
	want=YsSmaller(want,sqrt(2.0*FSRVB_TAXI_PLAN_DECEL*YsGreater(0.0,toEnd-0.5)));
	if(toEnd>FSRVB_ROUTE_END)
	{
		want=YsGreater(want,0.8);  // Creep the last metres
	}

	// Traffic: car-following, then the hold line before the rearm zone (way in) or the runway (way out)
	const double follow=FsRvbTraffic::FollowLimit(air,sim,r,sRoute,FSRVB_TAXI_PLAN_DECEL);
	if(follow<want)
	{
		want=follow;
		holding=(follow<0.5 ? YSTRUE : YSFALSE);
	}
	const YsString zone=RearmZone(spotIdx);
	const double toLine=holdLineS-sRoute;
	if(PHASE_TAXI_IN==phase)
	{
		if(fabs(plan->Cross(pos))>plan->width/2.0+FSRVB_RUNWAY_CLEAR)
		{
			FsRvbTraffic::Release(plan,"RUNWAY",air.SearchKey());  // Off the runway: free for the next arrival
		}
		if(0.0<toLine && toLine<200.0 && YSTRUE!=FsRvbTraffic::Book(plan,zone,air.SearchKey()))
		{
			want=YsSmaller(want,sqrt(2.0*FSRVB_TAXI_PLAN_DECEL*toLine));
			holding=YSTRUE;
		}
	}
	else
	{
		if((plan->rearm[spotIdx].stopPos-pos).GetLengthXZ()>FSRVB_REARM_ZONE_RADIUS)
		{
			FsRvbTraffic::Release(plan,zone,air.SearchKey());
		}
		if(toLine<200.0)
		{
			// Landing traffic first: no runway while an arrival is close in.  Past the line the jet is committed:
			// it keeps (or takes) the booking; without it (another jet holds the runway) it stops where it is.
			YSBOOL go=YSFALSE;
			if(toLine<=0.0)
			{
				go=FsRvbTraffic::Book(plan,"RUNWAY",air.SearchKey());
			}
			else if(YSTRUE!=FsRvbTraffic::ArrivalWithin(sim,plan,FSRVB_DEPARTURE_ARRIVAL_GAP,air))
			{
				go=FsRvbTraffic::Book(plan,"RUNWAY",air.SearchKey());
			}
			else
			{
				FsRvbTraffic::Release(plan,"RUNWAY",air.SearchKey());
			}
			if(YSTRUE!=go)
			{
				want=YsSmaller(want,sqrt(2.0*FSRVB_TAXI_PLAN_DECEL*YsGreater(0.0,toLine)));
				holding=YSTRUE;
			}
		}
	}
	taxiSpeed=want;

	// Arrived, or stuck
	if(toEnd<FSRVB_ROUTE_END || (toEnd<8.0 && v<0.3 && 3.0<stillTimer))
	{
		if(PHASE_TAXI_IN==phase)
		{
			const FsRvbRearmSpot &spot=plan->rearm[spotIdx];
			report.rearmStopError=(spot.stopPos-pos).GetLengthXZ();
			report.rearmSpot=spot.name;
			SetPhase(PHASE_REARM);
		}
		else
		{
			SetPhase(PHASE_LINEUP);
		}
		return;
	}
	if(v<0.3 && YSTRUE!=holding)
	{
		stillTimer+=dt;
		if(FSRVB_STUCK_TIME<stillTimer)
		{
			Fail("stuck while taxiing");
		}
	}
	else
	{
		stillTimer=0.0;
	}
}

void FsRvbArrival::DecideRearm(FsAirplane &air,FsSimulation *sim)
{
	if(FSRVB_REARM_STOP_TIME<=phaseTimer && FSGROUNDSTATIC==air.Prop().GetFlightState())
	{
		YSBOOL fuel,ammo;
		if(NULL!=sim->FindNearbySupplyTruck(fuel,ammo,air))
		{
			if(YSTRUE==fuel)
			{
				air.Prop().LoadFuel();
			}
			if(YSTRUE==ammo)
			{
				air.RecallReloadCommandOnly();
			}
			report.rearmed=YSTRUE;
		}
		else
		{
			report.failReason.Set("rearm stop too far from the supply object");
		}
		report.rearmTime=clock;
		BeginRoute(plan->rearm[spotIdx].out,air,YSTRUE);
		SetPhase(PHASE_TAXI_OUT);
	}
	else if(30.0<phaseTimer)
	{
		Fail("never came to a full stop at the rearm spot");
	}
}

void FsRvbArrival::DecideLineUp(FsAirplane &air)
{
	// The way out ends in a U-turn onto the runway: finish it slowly on the centre line before full power.
	const YsVec3 &pos=air.GetPosition();
	aim=plan->OnCentreLine(plan->Along(pos)+FSRVB_LINEUP_LOOKAHEAD);
	taxiSpeed=FSRVB_LINEUP_SPEED;
	const double rwyH=atan2(-plan->landDir.x(),plan->landDir.z());
	double dh=air.GetAttitude().h()-rwyH;
	dh=atan2(sin(dh),cos(dh));
	if((fabs(dh)<FSRVB_LINEUP_HEADING && fabs(plan->Cross(pos))<FSRVB_LINEUP_CROSS) || FSRVB_LINEUP_MAX_TIME<phaseTimer)
	{
		SetPhase(PHASE_TAKEOFF);
	}
}

void FsRvbArrival::DecideTakeOff(FsAirplane &air,FsSimulation *sim)
{
	const YsVec3 &pos=air.GetPosition();
	const double along=plan->Along(pos);
	aim=plan->OnCentreLine(along+FSRVB_TAKEOFF_LOOKAHEAD+FSRVB_TAKEOFF_LOOKAHEAD_TIME*FsRvbHands::GroundSpeed(air));
	if(YSTRUE!=air.Prop().IsOnGround() && pos.y()-RunwayElevation(sim)>FSRVB_LIFTOFF_HEIGHT)
	{
		report.liftoffAlong=along;
		report.liftoffSpeed=air.Prop().GetVelocity();
		liftoffClock=clock;
		liftoffPos=pos;
		SetPhase(PHASE_CLIMB);
	}
	else if(along>plan->length+100.0 && YSTRUE==air.Prop().IsOnGround())
	{
		Fail("ran off the runway end on the take-off roll");
	}
}

void FsRvbArrival::DecideClimb(FsAirplane &air,FsSimulation *sim)
{
	const YsVec3 &pos=air.GetPosition();
	const double rwyY=RunwayElevation(sim);
	const double height=pos.y()-rwyY;
	const double past=(pos-liftoffPos).GetLengthXZ();
	const double v=air.Prop().GetVelocity();
	FsRvbTraffic::Release(plan,"RUNWAY",air.SearchKey());

	aim=plan->OnCentreLine(plan->Along(pos)+YsGreater(2000.0,v*FSRVB_AIR_LOOKAHEAD_TIME));
	intent.bank=FsRvbHands::BankToward(air,aim,FSRVB_CLIMB_MAX_BANK);

	// The user's climb-out: height and speed by distance past lift-off
	double hWant=FSRVB_CRUISE_HEIGHT,vWant=200.0;
	const double dLead=past+v*FSRVB_VERT_LEAD;
	for(int i=0; i+1<plan->climb.GetN(); ++i)
	{
		const FsRvbClimbPoint &c0=plan->climb[i],&c1=plan->climb[i+1];
		if(dLead<=c1.dist || i+2==plan->climb.GetN())
		{
			const double t=YsBound((dLead-c0.dist)/YsGreater(1.0,c1.dist-c0.dist),0.0,1.0);
			hWant=c0.height*(1.0-t)+c1.height*t;
			vWant=c0.speed*(1.0-t)+c1.speed*t;
			break;
		}
	}
	if(PHASE_DONE==phase)
	{
		hWant=FSRVB_CRUISE_HEIGHT;
	}
	// Terrain: stay clear of the ground here and 2 km ahead (hills west of Cole)
	for(double ahead : {0.0,1000.0,2000.0})
	{
		const YsVec3 q=pos+plan->landDir*ahead;
		hWant=YsGreater(hWant,sim->GetFieldElevation(q.x(),q.z())-rwyY+FSRVB_MIN_AGL*3.0);
	}
	intent.vSpeed=YsBound((rwyY+hWant-pos.y())/FSRVB_VERT_LEAD,-10.0,FSRVB_VSPEED_MAX_UP);
	intent.speed=vWant;
	intent.gMax=3.0;
	intent.gMin=0.0;
	intent.afterburner=YSTRUE;  // The user climbs out in afterburner
	intent.spoiler=YSFALSE;
	intent.spoilerForSpeed=YSFALSE;
	intent.idle=YSFALSE;
	intent.gear=(height>FSRVB_GEAR_UP_HEIGHT ? 0.0 : 1.0);
	intent.flap=(height>FSRVB_FLAP_UP_HEIGHT ? 0.0 : 1.0);

	if(PHASE_CLIMB==phase && past>FSRVB_DONE_DIST && height>FSRVB_DONE_HEIGHT)
	{
		report.airborne=YSTRUE;
		report.airborneTime=clock;
		if(NULL!=plan && YSNULLHASHKEY!=airKey)
		{
			FsRvbTraffic::ReleaseAll(airKey);
			FsRvbTraffic::LeaveHold(plan,airKey);
		}
		SetPhase(PHASE_DONE);
	}
}

/* virtual */ YSRESULT FsRvbArrival::ApplyControl(FsAirplane &air,FsSimulation *,const double &dt)
{
	switch(phase)
	{
	case PHASE_APPROACH:
	case PHASE_HOLDING:
	case PHASE_CLIMB:
	case PHASE_DONE:
		hands.Fly(air,intent,dt);
		break;
	case PHASE_FLARE:
		hands.SetSpoiler(1.0);  // The user has spoilers out in the flare
		hands.SetGearFlap(1.0,1.0);
		hands.Flare(air,flareBank,flareVSpeed,air.Prop().GetTailStrikePitchAngle(0.8),dt);
		break;
	case PHASE_TAXI_IN:
		hands.SetSpoiler(1.0);
		hands.Taxi(air,aim,taxiSpeed,dt);
		break;
	case PHASE_TAXI_OUT:
	case PHASE_LINEUP:
		hands.SetSpoiler(0.0);
		hands.Taxi(air,aim,taxiSpeed,dt);
		break;
	case PHASE_TAKEOFF:
		{
			const double pitch=(air.Prop().GetVelocity()>=plan->rotateSpeed ?
			                    YsSmaller(plan->liftoffPitch,air.Prop().GetTailStrikePitchAngle(0.8)) : 0.0);
			hands.TakeOffRoll(air,aim,YSTRUE,pitch,dt);
		}
		break;
	case PHASE_REARM:
	case PHASE_FAILED:
	default:
		if(YSTRUE==air.Prop().IsOnGround())
		{
			hands.Hold(air,dt);
		}
		else
		{
			FsRvbHands::AirIntent level;
			level.speed=150.0;
			level.gear=0.0;
			hands.Fly(air,level,dt);
		}
		break;
	}
	return YSOK;
}
