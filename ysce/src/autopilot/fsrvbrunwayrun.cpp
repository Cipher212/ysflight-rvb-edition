#include <ysclass.h>

#include "fs.h"
#include "fsrvbrunwayrun.h"
#include "fsrvbsurvival.h"
#include "fsrvbdoctrine.h"

// RvB: see fsrvbrunwayrun.h (YSFlight RvB Edition, 2026-09-30).

static const double FSRVB_RUN_CLIMB_RATE=20.0;   // m/s
static const double FSRVB_RUN_SETTLE_TIME=20.0;  // s of straight flight before the first release
static const double FSRVB_RUN_G=2.0;             // Gentle: heavies fly straight and level
static const double FSRVB_RUN_THROTTLE=0.9;
static const double FSRVB_RUN_FIRST=0.1;         // Impact points from 10% ...
static const double FSRVB_RUN_LAST=0.9;          // ... to 90% of the runway
static const double FSRVB_CLIMB_TIMEOUT=240.0;   // s

FsRvbRunwayRun::FsRvbRunwayRun()
{
	phase=PHASE_IDLE;
	nAim=0;
	nextAim=0;
	nReleased=0;
	phaseTimer=0.0;
	run[0]=YsOrigin();
	run[1]=YsOrigin();
	climbPos=YsOrigin();
	homeDir=YsZVec();
}

void FsRvbRunwayRun::Start(const YsVec3 &runStart,const YsVec3 &runEnd,const YsVec3 &climbPosIn,const YsVec3 &homeDirIn)
{
	run[0]=runStart;
	run[1]=runEnd;
	climbPos=climbPosIn;
	homeDir=homeDirIn;
	phase=PHASE_CLIMB;
	phaseTimer=0.0;
	nAim=0;
	nextAim=0;
	nReleased=0;
}

FsRvbRunwayRun::PHASE FsRvbRunwayRun::GetPhase(void) const
{
	return phase;
}

int FsRvbRunwayRun::GetNumReleased(void) const
{
	return nReleased;
}

/* static */ int FsRvbRunwayRun::CountBombs(const FsAirplane &air)
{
	return air.Prop().GetNumWeapon(FSWEAPON_BOMB)+air.Prop().GetNumWeapon(FSWEAPON_BOMB250)+air.Prop().GetNumWeapon(FSWEAPON_BOMB500HD);
}

/* static */ FSWEAPONTYPE FsRvbRunwayRun::NextBombType(const FsAirplane &air)
{
	if(0<air.Prop().GetNumWeapon(FSWEAPON_BOMB))
	{
		return FSWEAPON_BOMB;
	}
	if(0<air.Prop().GetNumWeapon(FSWEAPON_BOMB250))
	{
		return FSWEAPON_BOMB250;
	}
	return FSWEAPON_BOMB500HD;
}

YsVec3 FsRvbRunwayRun::AimPoint(int i) const
{
	const double f=FSRVB_RUN_FIRST+(FSRVB_RUN_LAST-FSRVB_RUN_FIRST)*((double)i+0.5)/(double)YsGreater(1,nAim);
	return run[0]+(run[1]-run[0])*f;
}

void FsRvbRunwayRun::Update(FsRvbSteer &steer,FsAirplane &air,FsSimulation *sim,const FsRvbDoctrine &doc,const double dt)
{
	phaseTimer+=dt;
	const YsVec3 &pos=air.GetPosition();
	YsVec3 dir=run[1]-run[0];
	dir.SetY(0.0);
	const double lng=dir.GetLength();
	if(YSOK!=dir.Normalize())
	{
		phase=PHASE_DONE;
		return;
	}
	const YsVec3 perp(-dir.z(),0.0,dir.x());
	const double alt=run[0].y()+doc.attackAlt;

	steer.Clear();
	steer.throttle=FSRVB_RUN_THROTTLE;

	YsVec3 vel;
	air.Prop().GetVelocity(vel);
	vel.SetY(0.0);
	const double vh=vel.GetLength();
	const double h=YsGreater(1.0,pos.y()-run[0].y());
	const double tFall=sqrt(2.0*h/FsGravityConst);

	switch(phase)
	{
	default:
		break;
	case PHASE_CLIMB:
		{
			YsVec3 target=climbPos;
			target.SetY(alt);
			steer.FlyTo(air,target,FSRVB_RUN_G,FSRVB_RUN_CLIMB_RATE);
			if(pos.y()>=alt-300.0 || FSRVB_CLIMB_TIMEOUT<phaseTimer)
			{
				phase=PHASE_INGRESS;
				phaseTimer=0.0;
			}
		}
		break;
	case PHASE_INGRESS:
		{
			YsVec3 ip=run[0]-dir*(vh*tFall+vh*FSRVB_RUN_SETTLE_TIME);
			ip.SetY(alt);
			steer.FlyTo(air,ip,FSRVB_RUN_G,FSRVB_RUN_CLIMB_RATE);
			const YsVec3 rel=pos-ip;
			if(rel.GetSquareLengthXZ()<1500.0*1500.0)
			{
				phase=PHASE_RUN;
				phaseTimer=0.0;
				nAim=CountBombs(air);
				nextAim=0;
			}
		}
		break;
	case PHASE_RUN:
		{
			// Hold the centre line.
			const double lateral=(pos-run[0])*perp;
			YsVec3 want=dir-perp*YsBound(lateral/1500.0,-0.5,0.5);
			want.Normalize();
			steer.TurnTowards(air,want,FSRVB_RUN_G,YsBound((alt-pos.y())/10.0,-10.0,10.0));
			air.Prop().SetBombBayDoor(1.0);

			// Walk the bombs down the runway: release when the predicted impact passes the next aim point.
			const YsVec3 impact=pos+vel*tFall;
			const double along=(impact-run[0])*dir;
			while(nextAim<nAim && 0<CountBombs(air) && along>=(AimPoint(nextAim)-run[0])*dir)
			{
				YSBOOL blockedByBombBay;
				if(YSTRUE!=air.Prop().FireWeapon(blockedByBombBay,sim,sim->GetClock(),sim->GetWeaponStore(),&air,NextBombType(air)))
				{
					break;  // Bomb bay still opening: next tick
				}
				++nextAim;
				++nReleased;
			}
			if(nAim<=nextAim || 0==CountBombs(air) || lng+500.0<along)
			{
				phase=PHASE_EGRESS;
				phaseTimer=0.0;
			}
		}
		break;
	case PHASE_EGRESS:
		air.Prop().SetBombBayDoor(0.0);
		steer.TurnTowards(air,homeDir,FSRVB_RUN_G,0.0);
		if(10.0<phaseTimer && fabs(FsRvbRelativeHeading(air,homeDir))<YsDegToRad(10.0))
		{
			phase=PHASE_DONE;
		}
		break;
	}
}
