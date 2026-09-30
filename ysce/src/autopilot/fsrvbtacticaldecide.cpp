#include <ysclass.h>

#include "fs.h"
#include "fsutil.h"
#include "fsrvbtacticalautopilot.h"
#include "fsrvbteampicture.h"
#include "fsrvbroletasks.h"

// RvB: the RvB tactical AI - decisions per scan and per task (YSFlight RvB Edition, 2026-09-30).

static const double FSRVB_JUMPED_DEFAULT=2500.0;   // m, roles without their own jumped range
static const double FSRVB_BUGOUT_MIN_TIME=20.0;    // s running before looking again
static const double FSRVB_BUGOUT_CLEAR=6000.0;     // m: no known enemy this close -> bug-out over
static const double FSRVB_BUGOUT_AGL=150.0;        // m
static const double FSRVB_BUGOUT_AB_TIME=20.0;     // s of afterburner
static const double FSRVB_EXTEND_TIME=20.0;        // s
static const double FSRVB_SLASH_MAX_TIME=30.0;     // s: STEALTH never stays in a fight longer
static const double FSRVB_SLASH_MERGE=1200.0;      // m: closer than this and not on the nose -> leave
static const double FSRVB_DEFEND_STEALTH_TIME=6.0; // s of max-G break before extending
static const double FSRVB_SNAPSHOT_RANGE=2500.0;   // m
static const double FSRVB_SNAPSHOT_CONE=YsDegToRad(25.0);
static const double FSRVB_SNAPSHOT_INTERVAL=8.0;   // s
static const double FSRVB_STATION_ORBIT=3000.0;    // m orbit radius at the station
static const double FSRVB_STATION_THROTTLE=0.8;

void FsRvbTacticalAutopilot::Scan(FsAirplane &air,FsSimulation *sim,const FsRvbTeamPicture &pic)
{
	const double scanDt=clock-lastScanClock;
	lastScanClock=clock;
	const int dmg=air.Prop().GetDamageTolerance();
	const YSBOOL gotHit=(dmg<lastDamage ? YSTRUE : YSFALSE);
	lastDamage=dmg;

	aware.Scan(air,pic,*doc,clock,scanDt,gotHit);
	survival.UpdateFuel(air,clock);

	// Jumped: an enemy it knows of, behind it with its nose on it.  Checked first: it comes before going
	// home (a jet running home in a straight line is easy prey).
	const double jumped=(0.0<doc->jumpedRange ? doc->jumpedRange : FSRVB_JUMPED_DEFAULT);
	const YSHASHKEY behind=aware.KnownThreatBehind(air,pic,jumped);
	if(TASK_RTB==task && (YSNULLHASHKEY==behind || FSRVBROLE_HEAVY==role))
	{
		return;  // On the way home
	}
	if(TASK_RTB==task)
	{
		recovery.Stop();  // Deal with the attacker; the next clear scan sends it home again
	}
	if(YSNULLHASHKEY==behind && YSTRUE==groundOps)
	{
		const FsRvbSurvival::RTB_REASON why=survival.NeedRtb(air,pic,*doc);
		if(FsRvbSurvival::RTB_NONE!=why)
		{
			++FsRvbSurvival::nRtb[why];
			StartRtb(air,sim,pic);
			return;
		}
	}

	// Odds against us: clean up and leave low.
	if(TASK_BUGOUT!=task && YSTRUE==survival.OddsAgainstUs(air,pic,aware,*doc))
	{
		FsRvbSurvival::DropTanks(air,sim);
		SetTask(TASK_BUGOUT);
		return;
	}
	if(TASK_BUGOUT==task)
	{
		if(taskTimer<FSRVB_BUGOUT_MIN_TIME || FsRvbRoleTasks::NearestKnownEnemy(air,pic,aware)<FSRVB_BUGOUT_CLEAR)
		{
			return;
		}
		SetTask(TASK_STATION);
	}

	if(YSNULLHASHKEY!=behind)
	{
		switch(role)
		{
		case FSRVBROLE_MULTIROLE:
			if(TASK_A2G==task || YSTRUE==FsRvbSurvival::HasGroundWeapon(air,*doc))
			{
				FsRvbSurvival::DropTanks(air,sim);
				FsRvbSurvival::DropBombs(air);
			}
			StartAirTask(air,sim,behind);
			return;
		default:
		case FSRVBROLE_GUNNER:
		case FSRVBROLE_UCAV:
			StartAirTask(air,sim,behind);
			return;
		case FSRVBROLE_STEALTH:
		case FSRVBROLE_ATTACKER:
		case FSRVBROLE_CAS:
			threatKey=behind;
			SetTask(TASK_DEFEND);
			return;
		case FSRVBROLE_HEAVY:
			break;  // No manoeuvring skills: presses on (the odds check sends it home)
		}
	}
	else if(TASK_DEFEND==task)
	{
		SetTask(TASK_STATION);  // Clear: back to work
	}

	if(TASK_EXTEND==task && taskTimer<FSRVB_EXTEND_TIME)
	{
		return;
	}
	if(TASK_RUNWAY==task && FsRvbRunwayRun::PHASE_DONE!=runwayRun.GetPhase())
	{
		return;
	}
	ChooseTask(air,sim,pic);
}

void FsRvbTacticalAutopilot::ChooseTask(FsAirplane &air,FsSimulation *sim,const FsRvbTeamPicture &pic)
{
	stationPos=FsRvbRoleTasks::StationPosition(air,pic,*doc,slot);
	const YSHASHKEY curAir=(TASK_A2A==task ? airTargetKey : YSNULLHASHKEY);
	const YSHASHKEY curGnd=(TASK_A2G==task ? gndTargetKey : YSNULLHASHKEY);

	switch(role)
	{
	default:
	case FSRVBROLE_GUNNER:
	case FSRVBROLE_UCAV:
		{
			const YSHASHKEY t=FsRvbRoleTasks::ChooseAirTarget(air,pic,aware,*doc,curAir,stationPos);
			if(YSNULLHASHKEY!=t)
			{
				StartAirTask(air,sim,t);
				return;
			}
		}
		break;
	case FSRVBROLE_MULTIROLE:
		{
			const YSHASHKEY t=FsRvbRoleTasks::ChooseAirTarget(air,pic,aware,*doc,curAir,stationPos);
			if(YSNULLHASHKEY!=t)
			{
				StartAirTask(air,sim,t);
				return;
			}
			if(YSTRUE==FsRvbSurvival::HasGroundWeapon(air,*doc) &&
			   doc->noAirThreatRange<FsRvbRoleTasks::NearestKnownEnemy(air,pic,aware))
			{
				const YSHASHKEY g=FsRvbRoleTasks::ChooseGroundTarget(air,sim,pic,*doc,curGnd);
				if(YSNULLHASHKEY!=g)
				{
					StartGroundTask(air,sim,g);
					return;
				}
			}
		}
		break;
	case FSRVBROLE_STEALTH:
		{
			if(TASK_A2A==task && YSTRUE==StealthShouldExtend(air,sim,pic))
			{
				StartExtend(air,pic,airTargetKey);
				return;
			}
			const YSHASHKEY t=FsRvbRoleTasks::ChooseAirTarget(air,pic,aware,*doc,curAir,stationPos);
			if(YSNULLHASHKEY!=t)
			{
				StartAirTask(air,sim,t);
				return;
			}
			if(TASK_A2G==task && YSNULLHASHKEY!=curGnd)
			{
				return;  // Finish the stand-off attack
			}
			if(YSTRUE==FsRvbSurvival::HasGroundWeapon(air,*doc) &&
			   doc->noAirThreatRange<FsRvbRoleTasks::NearestKnownEnemy(air,pic,aware) &&
			   FsGetRandomBetween(0.0,1.0)<doc->a2gChance)
			{
				const YSHASHKEY g=FsRvbRoleTasks::ChooseGroundTarget(air,sim,pic,*doc,YSNULLHASHKEY);
				if(YSNULLHASHKEY!=g)
				{
					StartGroundTask(air,sim,g);
					return;
				}
			}
		}
		break;
	case FSRVBROLE_ATTACKER:
	case FSRVBROLE_CAS:
		{
			const YSHASHKEY g=FsRvbRoleTasks::ChooseGroundTarget(air,sim,pic,*doc,curGnd);
			if(YSNULLHASHKEY!=g)
			{
				StartGroundTask(air,sim,g);
				return;
			}
		}
		break;
	case FSRVBROLE_HEAVY:
		if(0<air.Prop().GetNumWeapon(FSWEAPON_BOMB)+air.Prop().GetNumWeapon(FSWEAPON_BOMB250)+air.Prop().GetNumWeapon(FSWEAPON_BOMB500HD))
		{
			YsVec3 runStart,runEnd;
			if(0<=FsRvbRoleTasks::ChooseRunway(runStart,runEnd,air,pic,runCount))
			{
				runwayRun.Start(runStart,runEnd,stationPos,pic.map.OwnSideDir(air.iff));
				++runCount;
				SetTask(TASK_RUNWAY);
				return;
			}
		}
		break;
	}
	SetTask(TASK_STATION);
}

YSBOOL FsRvbTacticalAutopilot::StealthShouldExtend(FsAirplane &air,FsSimulation *,const FsRvbTeamPicture &pic)
{
	// Slash and extend: after a long shot, when it would turn into a knife fight, or after too long.
	const int nAim120=air.Prop().GetNumWeapon(FSWEAPON_AIM120);
	const YSBOOL fired=(nAim120<aim120Left ? YSTRUE : YSFALSE);
	aim120Left=nAim120;
	if(YSTRUE==fired || FSRVB_SLASH_MAX_TIME<taskTimer)
	{
		return YSTRUE;
	}
	const FsRvbTeamPicture::AirContact *trg=pic.FindAir(airTargetKey);
	if(NULL!=trg)
	{
		YsVec3 toTrg=trg->pos-air.GetPosition();
		if(toTrg.GetSquareLength()<FSRVB_SLASH_MERGE*FSRVB_SLASH_MERGE &&
		   YsDegToRad(20.0)<fabs(FsRvbRelativeHeading(air,toTrg)))
		{
			return YSTRUE;  // No clean gun pass: leave
		}
	}
	return YSFALSE;
}

void FsRvbTacticalAutopilot::StartAirTask(FsAirplane &,FsSimulation *sim,YSHASHKEY target)
{
	if(TASK_A2A!=task || airTargetKey!=target)
	{
		FsAirplane *trg=sim->FindAirplane(target);
		if(NULL==trg)
		{
			return;
		}
		a2a->SetTarget(trg);
		airTargetKey=target;
	}
	SetTask(TASK_A2A);
}

void FsRvbTacticalAutopilot::StartGroundTask(FsAirplane &air,FsSimulation *sim,YSHASHKEY target)
{
	if(TASK_A2G!=task || gndTargetKey!=target)
	{
		FsGround *gnd=sim->FindGround(target);
		if(NULL==gnd)
		{
			return;
		}
		a2g->target=gnd;
		a2g->SetAttackerAltitude(gnd->GetPosition().y()+doc->attackAlt);  // The role's height is above the target
		air.Prop().SetGroundTargetKey(target);
		a2g->SetPhase(air,FsGroundAttack::STATE_GETTINGTHERE);
		gndTargetKey=target;
	}
	SetTask(TASK_A2G);
}

void FsRvbTacticalAutopilot::StartExtend(FsAirplane &air,const FsRvbTeamPicture &pic,YSHASHKEY from)
{
	const FsRvbTeamPicture::AirContact *c=pic.FindAir(from);
	extendDir=(NULL!=c ? air.GetPosition()-c->pos : air.GetAttitude().GetForwardVector());
	extendDir.SetY(0.0);
	if(YSOK!=extendDir.Normalize())
	{
		extendDir=pic.map.OwnSideDir(air.iff);
	}
	SetTask(TASK_EXTEND);
}

void FsRvbTacticalAutopilot::StartRtb(FsAirplane &air,FsSimulation *sim,const FsRvbTeamPicture &pic)
{
	recovery.StartRtb(air,sim,pic);
	SetTask(TASK_RTB);
}

void FsRvbTacticalAutopilot::DecideSteer(FsAirplane &air,FsSimulation *sim,const FsRvbTeamPicture &pic,const double dt)
{
	steer.Clear();
	const YsVec3 &pos=air.GetPosition();
	switch(task)
	{
	default:
	case TASK_STATION:
		{
			YsVec3 rel=stationPos-pos;
			rel.SetY(0.0);
			const double d=rel.GetLength();
			if(FSRVB_STATION_ORBIT<d)
			{
				steer.FlyTo(air,stationPos,YsSmaller(doc->gLimit,4.0),20.0);
			}
			else
			{
				// Orbit: tangent, pulled in or out towards the orbit radius.
				rel.Normalize();
				YsVec3 dir(-rel.z(),0.0,rel.x());
				dir+=rel*((d-FSRVB_STATION_ORBIT*0.7)/FSRVB_STATION_ORBIT);
				dir.Normalize();
				steer.TurnTowards(air,dir,2.5,YsBound((stationPos.y()-pos.y())/10.0,-20.0,20.0));
			}
			steer.throttle=FSRVB_STATION_THROTTLE;
		}
		break;
	case TASK_EXTEND:
		steer.TurnTowards(air,extendDir,doc->gLimit,(pos.y()<doc->stationAlt[1] ? 15.0 : 0.0));  // Zoom back up
		steer.throttle=1.0;
		steer.afterburner=YSTRUE;
		break;
	case TASK_BUGOUT:
		{
			const double agl=air.GetAGL();
			steer.TurnTowards(air,pic.map.OwnSideDir(air.iff),doc->gLimit,YsBound((FSRVB_BUGOUT_AGL-agl)/4.0,-40.0,20.0));
			steer.throttle=1.0;
			steer.afterburner=(taskTimer<FSRVB_BUGOUT_AB_TIME ? YSTRUE : YSFALSE);
		}
		break;
	case TASK_DEFEND:
		{
			const FsRvbTeamPicture::AirContact *threat=pic.FindAir(threatKey);
			if(NULL==threat)
			{
				SetTask(TASK_STATION);
				break;
			}
			YsVec3 toThreat=threat->pos-pos;
			const double dist=toThreat.GetLength();
			const double rel=FsRvbRelativeHeading(air,toThreat);

			// Break turn into the attacker, full power.
			steer.active=YSTRUE;
			steer.bank=(0.0<=rel ? 1.0 : -1.0)*YsDegToRad(80.0);
			if(pos.y()<TaskMinAlt()+300.0)
			{
				steer.useVSpeed=YSTRUE;
				steer.vSpeed=0.0;
				steer.gLimit=doc->gEvade;
			}
			else
			{
				steer.useVSpeed=YSFALSE;
				steer.g=doc->gEvade;
			}
			steer.throttle=1.0;
			steer.afterburner=YSTRUE;

			if(fabs(rel)<FSRVB_SNAPSHOT_CONE && dist<FSRVB_SNAPSHOT_RANGE)
			{
				SnapshotShot(air,sim);
			}
			if(FSRVBROLE_STEALTH==role && FSRVB_DEFEND_STEALTH_TIME<taskTimer)
			{
				StartExtend(air,pic,threatKey);
			}
		}
		break;
	case TASK_RUNWAY:
		runwayRun.Update(steer,air,sim,*doc,dt);
		if(FsRvbRunwayRun::PHASE_DONE==runwayRun.GetPhase())
		{
			SetTask(TASK_STATION);
			scanTimer=0.0;
		}
		break;
	}
}

void FsRvbTacticalAutopilot::SnapshotShot(FsAirplane &air,FsSimulation *sim)
{
	if(0.0<snapshotTimer)
	{
		return;
	}
	FSWEAPONTYPE type=FSWEAPON_NULL;
	if(0!=(doc->aamMask&FSRVBAAM_AIM9X) && 0<air.Prop().GetNumWeapon(FSWEAPON_AIM9X))
	{
		type=FSWEAPON_AIM9X;
	}
	else if(0!=(doc->aamMask&FSRVBAAM_AIM9) && 0<air.Prop().GetNumWeapon(FSWEAPON_AIM9))
	{
		type=FSWEAPON_AIM9;
	}
	if(FSWEAPON_NULL==type)
	{
		return;
	}
	YSBOOL blockedByBombBay;
	air.Prop().SetAirTargetKey(threatKey);
	air.Prop().FireWeapon(blockedByBombBay,sim,sim->GetClock(),sim->GetWeaponStore(),&air,type);
	snapshotTimer=FSRVB_SNAPSHOT_INTERVAL;
}
