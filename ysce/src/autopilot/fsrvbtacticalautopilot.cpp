#include <ysclass.h>

#include "fs.h"
#include "fsutil.h"
#include "fsrvbtacticalautopilot.h"
#include "fsrvbteampicture.h"
#include "fsrvbroletasks.h"

// RvB: the RvB tactical AI - lifecycle and per-tick flow (YSFlight RvB Edition, 2026-09-30).
// Decisions per scan and per task are in fsrvbtacticaldecide.cpp.

static const double FSRVB_SCAN_INTERVAL[2]={1.5,2.5};  // s of sim time between an AI's scans
static const double FSRVB_MINALT_LOW=40.0;              // m: roles that fly low on purpose
static const double FSRVB_MINALT=250.0;
static const double FSRVB_PARKED_RETRY=10.0;           // s: parked without a runway, look again
static const double FSRVB_TERRAIN_INTERVAL=0.25;        // s between terrain samples
static const double FSRVB_TERRAIN_CLEAR=150.0;          // m above the terrain ahead
static const double FSRVB_TERRAIN_CLEAR_LOW=50.0;       // m, roles that fly low on purpose

/* static */ YSBOOL FsRvbTacticalAutopilot::enabled=YSTRUE;
/* static */ YSBOOL FsRvbTacticalAutopilot::groundOps=YSFALSE;

FsRvbTacticalAutopilot::FsRvbTacticalAutopilot()
{
	role=FSRVBROLE_NONE;
	doc=&FsRvbGetDoctrine(FSRVBROLE_NONE);
	task=TASK_STATION;
	initialized=YSFALSE;
	steering=YSFALSE;
	clock=0.0;
	scanTimer=0.0;
	lastScanClock=0.0;
	taskTimer=0.0;
	snapshotTimer=0.0;
	lastDamage=0;
	slot=0;
	runCount=0;
	aim120Left=0;
	airTargetKey=YSNULLHASHKEY;
	gndTargetKey=YSNULLHASHKEY;
	threatKey=YSNULLHASHKEY;
	stationPos=YsOrigin();
	extendDir=YsZVec();
	terrainTimer=0.0;
	terrainTop=0.0;
	a2a=NULL;
	a2g=NULL;
}

FsRvbTacticalAutopilot::~FsRvbTacticalAutopilot()
{
	if(NULL!=a2a)
	{
		FsAutopilot::Delete(a2a);
	}
	if(NULL!=a2g)
	{
		FsAutopilot::Delete(a2g);
	}
}

/* static */ FsRvbTacticalAutopilot *FsRvbTacticalAutopilot::Create(FSRVBROLE role)
{
	FsRvbTacticalAutopilot *ap=new FsRvbTacticalAutopilot;
	ap->role=role;
	ap->doc=&FsRvbGetDoctrine(role);
	const FsRvbDoctrine &doc=*ap->doc;

	ap->a2a=FsDogfight::Create();
	ap->a2a->gLimit=doc.gLimit;
	ap->a2a->backSenseRange=YsDegToRad(doc.backSenseDeg);
	ap->a2a->minAlt=FSRVB_MINALT;
	ap->a2a->cruiseAlt=doc.stationAlt[0];
	ap->a2a->rvbGunRange=doc.gunRange;
	ap->a2a->rvbAamMask=doc.aamMask;  // FSRVBAAM_* uses the same bits
	ap->a2a->rvbPreferAim120=doc.preferAim120;
	ap->a2a->rvbExternalTarget=YSTRUE;
	ap->a2a->SetCloseInMaxSpeed(YSTRUE);

	ap->a2g=FsGroundAttack::Create();
	ap->a2g->SetAttackerAltitude(doc.attackAlt);
	ap->a2g->SetBomberAltitude(doc.attackAlt);
	ap->a2g->SetInboundSpeed(doc.inboundSpeed);
	ap->a2g->minAlt=FSRVB_MINALT_LOW;
	ap->a2g->takeEvasiveAction=YSFALSE;  // Being jumped is handled here, per role
	ap->a2g->breakOnMissile=YSFALSE;
	switch(role)
	{
	case FSRVBROLE_CAS:
		ap->a2g->turnRadius=1500.0;  // Flat pedal turns straight back onto the target
		break;
	case FSRVBROLE_ATTACKER:
		ap->a2g->turnRadius=3000.0;
		break;
	default:
		break;
	}
	for(int i=0; i<4; ++i)
	{
		ap->a2g->rvbWeaponPref[i]=doc.a2gWeapon[i];
	}
	ap->a2g->rvbAllowGun=doc.a2gGun;
	return ap;
}

/* static */ FsAutopilot *FsRvbTacticalAutopilot::WrapIntention(FsAirplane &air,FsAutopilot *ap)
{
	if(YSTRUE!=enabled || NULL==ap ||
	   (FSAUTOPILOT_DOGFIGHT!=ap->Type() && FSAUTOPILOT_GNDATTACK!=ap->Type()))
	{
		return ap;
	}
	const FSRVBROLE role=FsRvbRoleTable::GetRole(air.GetIdentifier());
	if(FSRVBROLE_NONE==role)
	{
		return ap;  // Helicopters and aircraft without a role keep the stock AI
	}
	FsAutopilot::Delete(ap);
	return Create(role);
}

/* static */ const char *FsRvbTacticalAutopilot::TaskToStr(TASK t)
{
	switch(t)
	{
	case TASK_LAUNCH:
		return "LAUNCH";
	default:
	case TASK_STATION:
		return "STATION";
	case TASK_A2A:
		return "A2A";
	case TASK_A2G:
		return "A2G";
	case TASK_RUNWAY:
		return "RUNWAY";
	case TASK_EXTEND:
		return "EXTEND";
	case TASK_DEFEND:
		return "DEFEND";
	case TASK_BUGOUT:
		return "BUGOUT";
	case TASK_RTB:
		return "RTB";
	}
}

FSRVBROLE FsRvbTacticalAutopilot::GetRole(void) const
{
	return role;
}

FsRvbTacticalAutopilot::TASK FsRvbTacticalAutopilot::GetTask(void) const
{
	return task;
}

YSHASHKEY FsRvbTacticalAutopilot::GetEngagedAirKey(void) const
{
	return (TASK_A2A==task || TASK_DEFEND==task ? (TASK_A2A==task ? airTargetKey : threatKey) : YSNULLHASHKEY);
}

const FsRvbRecovery &FsRvbTacticalAutopilot::GetRecovery(void) const
{
	return recovery;
}

const FsRvbAwareness &FsRvbTacticalAutopilot::GetAwareness(void) const
{
	return aware;
}

/* virtual */ YSBOOL FsRvbTacticalAutopilot::IsTakingOff(void) const
{
	switch(recovery.GetStage())
	{
	case FsRvbRecovery::STAGE_TAXI_TO_RUNWAY:
	case FsRvbRecovery::STAGE_LINEUP:
	case FsRvbRecovery::STAGE_CARRIER_TAXI:
	case FsRvbRecovery::STAGE_TAKEOFF:
		return YSTRUE;
	default:
		return YSFALSE;
	}
}

/* virtual */ YSBOOL FsRvbTacticalAutopilot::IsLanding(void)
{
	switch(recovery.GetStage())
	{
	case FsRvbRecovery::STAGE_APPROACH:
	case FsRvbRecovery::STAGE_ROLLOUT:
		return YSTRUE;
	default:
		return YSFALSE;
	}
}

/* virtual */ YSRESULT FsRvbTacticalAutopilot::SaveIntention(FILE *fp,const FsSimulation *sim)
{
	// Saved as the stock dogfight intention; loading it wraps it again from the aircraft's role.
	return a2a->SaveIntention(fp,sim);
}

void FsRvbTacticalAutopilot::SetTask(TASK t)
{
	if(task!=t)
	{
		task=t;
		taskTimer=0.0;
	}
}

double FsRvbTacticalAutopilot::TaskMinAlt(void) const
{
	if(TASK_BUGOUT==task || TASK_RTB==task ||
	   ((FSRVBROLE_ATTACKER==role || FSRVBROLE_CAS==role) && (TASK_A2G==task || TASK_STATION==task || TASK_DEFEND==task)))
	{
		return FSRVB_MINALT_LOW;
	}
	return FSRVB_MINALT;
}

/* static */ void FsRvbTacticalAutopilot::CaptureReloadCommand(FsAirplane &air)
{
	// The refuel stop re-arms with YS RecallReloadCommandOnly.  Missions without RELDCMND lines get the
	// loadout commands the aircraft was set up with.
	if(0<air.GetReloadCommand().GetN())
	{
		return;
	}
	for(auto &cmd : air.cmdLog)
	{
		if(0==strncmp(cmd,"UNLOADWP",8) || 0==strncmp(cmd,"LOADWEPN",8) || 0==strncmp(cmd,"INITIGUN",8))
		{
			air.AddReloadCommand(cmd);
		}
	}
}

void FsRvbTacticalAutopilot::Initialize(FsAirplane &air,FsSimulation *sim,const FsRvbTeamPicture &pic)
{
	initialized=YSTRUE;
	lastScanClock=clock;
	lastDamage=air.Prop().GetDamageTolerance();
	slot=(int)(air.SearchKey()%97);
	aim120Left=air.Prop().GetNumWeapon(FSWEAPON_AIM120);
	air.gLimit=doc->gLimit;
	CaptureReloadCommand(air);
	stationPos=FsRvbRoleTasks::StationPosition(air,pic,*doc,slot);
	scanTimer=FsGetRandomBetween(0.0,FSRVB_SCAN_INTERVAL[1]);  // Stagger the first scans

	if(YSTRUE==air.Prop().IsOnGround())
	{
		recovery.StartOnGround(air,sim,pic);
		SetTask(TASK_LAUNCH);
	}
	else
	{
		SetTask(TASK_STATION);
	}
}

/* virtual */ YSRESULT FsRvbTacticalAutopilot::MakePriorityDecision(FsAirplane &air)
{
	// No low-altitude or stall recovery on the ground, in the landing pattern or on the take-off roll.
	if(YSTRUE!=initialized || TASK_LAUNCH==task ||
	   (TASK_RTB==task && YSTRUE!=recovery.IsInTheAirPhase()) ||
	   YSTRUE==air.Prop().IsOnGround())
	{
		emr=EMR_NONE;
		return YSOK;
	}
	minAlt=TaskMinAlt();
	return FsAutopilot::MakePriorityDecision(air);
}

/* virtual */ YSRESULT FsRvbTacticalAutopilot::MakeDecision(FsAirplane &air,FsSimulation *sim,const double &dt)
{
	clock+=dt;
	const FsRvbTeamPicture &pic=FsRvbTeamPicture::Get(sim);
	if(YSTRUE!=initialized)
	{
		Initialize(air,sim,pic);
	}
	steering=YSFALSE;

	// Ground and landing phases belong to the recovery module.
	if(TASK_LAUNCH==task || (TASK_RTB==task && YSTRUE!=recovery.IsInTheAirPhase()))
	{
		recovery.MakeDecision(air,sim,pic,dt);
		if(FsRvbRecovery::STAGE_IDLE==recovery.GetStage() && YSTRUE==air.Prop().IsOnGround())
		{
			// No runway to use: stay parked, look again every few seconds.
			taskTimer+=dt;
			if(FSRVB_PARKED_RETRY<taskTimer)
			{
				taskTimer=0.0;
				recovery.StartOnGround(air,sim,pic);
			}
		}
		else if(FsRvbRecovery::STAGE_DONE==recovery.GetStage() || FsRvbRecovery::STAGE_IDLE==recovery.GetStage())
		{
			recovery.Stop();
			SetTask(TASK_STATION);
			scanTimer=0.0;
		}
		return YSOK;
	}

	taskTimer+=dt;
	snapshotTimer-=dt;

	// Missile defence overrides everything else, every tick.
	const FsRvbTeamPicture::AirContact *self=pic.FindAir(air.SearchKey());
	const int nMissileOnMe=(NULL!=self ? self->nMissileOnIt : 0);
	if(YSTRUE==survival.UpdateMissileDefence(steer,air,sim,nMissileOnMe,aware,*doc,TaskMinAlt(),dt))
	{
		if(FSRVBROLE_MULTIROLE==role && TASK_A2G==task)
		{
			// Shot at on a ground run: abort, clean the jet up.
			FsRvbSurvival::DropTanks(air,sim);
			FsRvbSurvival::DropBombs(air);
			SetTask(TASK_STATION);
			scanTimer=0.0;
		}
		steering=YSTRUE;
		return YSOK;
	}

	// Scan on the timer, or at once when the target is gone.
	YSBOOL targetGone=YSFALSE;
	if(TASK_A2A==task)
	{
		const FsAirplane *trg=sim->FindAirplane(airTargetKey);
		targetGone=(NULL==trg || YSTRUE!=trg->IsAlive() ? YSTRUE : YSFALSE);
	}
	else if(TASK_A2G==task)
	{
		targetGone=(NULL==a2g->target || YSTRUE!=a2g->target->IsAlive() ? YSTRUE : YSFALSE);
	}
	scanTimer-=dt;
	if(0.0>=scanTimer || YSTRUE==targetGone)
	{
		Scan(air,sim,pic);
		scanTimer=FsGetRandomBetween(FSRVB_SCAN_INTERVAL[0],FSRVB_SCAN_INTERVAL[1]);
	}

	switch(task)
	{
	case TASK_A2A:
		a2a->MakeDecision(air,sim,dt);
		break;
	case TASK_A2G:
		a2g->MakeDecision(air,sim,dt);
		break;
	case TASK_RTB:
		recovery.MakeDecision(air,sim,pic,dt);
		break;
	default:
		DecideSteer(air,sim,pic,dt);
		steering=YSTRUE;
		break;
	}
	return YSOK;
}

/* virtual */ YSRESULT FsRvbTacticalAutopilot::ApplyControl(FsAirplane &air,FsSimulation *sim,const double &dt)
{
	if(YSTRUE==steering)
	{
		ApplySteer(air,sim,steer,dt);
	}
	else
	{
		switch(task)
		{
		case TASK_A2A:
			a2a->ApplyControl(air,sim,dt);
			air.Prop().SetDispenseFlareButton(YSFALSE);  // Flares are ours: only against missiles it has noticed
			break;
		case TASK_A2G:
			a2g->ApplyControl(air,sim,dt);
			air.Prop().SetDispenseFlareButton(YSFALSE);
			break;
		case TASK_LAUNCH:
		case TASK_RTB:
			if(YSTRUE==recovery.IsSteering())
			{
				ApplySteer(air,sim,recovery.GetSteer(),dt);
				TerrainGuard(air,sim,dt);  // Low pattern: only the low clearance (TaskMinAlt is low in RTB)
				return YSOK;
			}
			recovery.ApplyControl(air,sim,dt);
			if(YSTRUE!=recovery.IsInTheAirPhase())
			{
				return YSOK;  // Landing, taxiing, taking off
			}
			break;
		default:
			break;
		}
	}
	TerrainGuard(air,sim,dt);
	return YSOK;
}

void FsRvbTacticalAutopilot::ApplySteer(FsAirplane &air,FsSimulation *sim,const FsRvbSteer &s,const double dt)
{
	air.Prop().NeutralDirectAttitudeControl();
	air.Prop().SetAllVirtualButton(YSFALSE);
	air.Prop().BankController(s.bank);
	if(YSTRUE==s.useVSpeed)
	{
		ControlGForVerticalSpeed(air,sim,s.vSpeed,s.gLimit);
	}
	else
	{
		air.Prop().GController(s.g);
	}
	air.Prop().TurnOffSpeedController();
	air.Prop().SetThrottle(s.throttle);
	air.Prop().SetAfterburner(s.afterburner);
	air.Prop().SetGear(s.gear);
	air.Prop().SetFlap(s.flap);
	air.Prop().SetSpoiler(s.spoiler);
	air.Prop().SetBrake(0.0);
	air.Prop().SetDispenseFlareButton(s.flare);
	air.Prop().SmartRudder(dt);
}

void FsRvbTacticalAutopilot::TerrainGuard(FsAirplane &air,FsSimulation *sim,const double dt)
{
	// YS's low-altitude recovery works on height above sea level; hills need a look at the ground ahead.
	// Terrain under and 2 s / 4 s ahead, sampled 4 times a second.
	terrainTimer-=dt;
	if(0.0>=terrainTimer)
	{
		terrainTimer=FSRVB_TERRAIN_INTERVAL;
		YsVec3 vel;
		air.Prop().GetVelocity(vel);
		const YsVec3 &pos=air.GetPosition();
		terrainTop=sim->GetFieldElevation(pos.x(),pos.z());
		for(double t : {2.0,4.0})
		{
			terrainTop=YsGreater(terrainTop,sim->GetFieldElevation(pos.x()+vel.x()*t,pos.z()+vel.z()*t));
		}
	}
	YsVec3 vel;
	air.Prop().GetVelocity(vel);
	const double clearance=(TaskMinAlt()<=FSRVB_MINALT_LOW ? FSRVB_TERRAIN_CLEAR_LOW : FSRVB_TERRAIN_CLEAR);
	const double y=air.GetPosition().y();
	if(y<terrainTop+clearance || y+vel.y()*3.0<terrainTop+clearance)
	{
		air.Prop().BankController(0.0);
		ControlGForVerticalSpeed(air,sim,20.0,doc->gLimit);
		air.Prop().TurnOffSpeedController();
		air.Prop().SetThrottle(1.0);
		air.Prop().SetAfterburner(YSTRUE);
	}
}
