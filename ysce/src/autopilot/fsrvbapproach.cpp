#include <ysclass.h>

#include "fs.h"
#include "fsrvbapproach.h"
#include "fsrvbsurvival.h"

// RvB: see fsrvbapproach.h (YSFlight RvB Edition, 2026-09-30).

/* static */ const double FsRvbApproach::finalLength=2500.0;  // m of straight final

static const double FSRVB_ENTRY_HEIGHT=400.0;        // m above the field
static const double FSRVB_DOWNWIND_HEIGHT=350.0;
static const double FSRVB_PATTERN_BANK=YsDegToRad(50.0);
static const double FSRVB_PATTERN_SPEED=1.3;         // x the estimated landing speed
static const double FSRVB_GLIDE_SLOPE=YsDegToRad(4.0);
static const double FSRVB_GATE_BELOW=0.8;            // Gate height = 80% of the glide path (YS straight-in needs below)
static const double FSRVB_PATTERN_TIMEOUT=240.0;     // s
static const double FSRVB_TOUCHDOWN_INSET=250.0;     // m, matches the recovery's touchdown point

FsRvbApproach::FsRvbApproach()
{
	phase=PHASE_IDLE;
	phaseTimer=0.0;
	totalTimer=0.0;
	thr=YsOrigin();
	dir=YsZVec();
	side=YsXVec();
	lng=2000.0;
	radius=800.0;
	patternSpeed=90.0;
}

void FsRvbApproach::SetPhase(PHASE p)
{
	phase=p;
	phaseTimer=0.0;
}

FsRvbApproach::PHASE FsRvbApproach::GetPhase(void) const
{
	return phase;
}

double FsRvbApproach::Along(const YsVec3 &p) const
{
	const YsVec3 rel=p-thr;
	return rel.x()*dir.x()+rel.z()*dir.z();
}

double FsRvbApproach::Lateral(const YsVec3 &p) const
{
	const YsVec3 rel=p-thr;
	return rel.x()*side.x()+rel.z()*side.z();
}

void FsRvbApproach::Start(const FsAirplane &air,const YsVec3 &threshold,const YsVec3 &landDir,const double runwayLength)
{
	thr=threshold;
	dir=landDir;
	dir.SetY(0.0);
	dir.Normalize();
	lng=runwayLength;

	// Pattern on the side the aircraft is already on.
	side.Set(-dir.z(),0.0,dir.x());
	if(0.0>Lateral(air.GetPosition()))
	{
		side=-side;
	}

	patternSpeed=FSRVB_PATTERN_SPEED*air.Prop().GetEstimatedLandingSpeed();
	radius=YsBound(patternSpeed*patternSpeed/(FsGravityConst*tan(FSRVB_PATTERN_BANK)),500.0,1200.0);
	totalTimer=0.0;
	SetPhase(PHASE_ENTRY);
}

void FsRvbApproach::Update(FsRvbSteer &steer,const FsAirplane &air,const double dt)
{
	phaseTimer+=dt;
	totalTimer+=dt;
	if(FSRVB_PATTERN_TIMEOUT<totalTimer && PHASE_GATE!=phase)
	{
		SetPhase(PHASE_FAILED);
	}

	const YsVec3 &pos=air.GetPosition();
	const double fieldY=thr.y();
	const double v=air.Prop().GetVelocity();
	const double gateY=fieldY+(finalLength+FSRVB_TOUCHDOWN_INSET)*tan(FSRVB_GLIDE_SLOPE)*FSRVB_GATE_BELOW;

	steer.Clear();
	steer.active=YSTRUE;

	// Speed: idle and speed brake when fast, power when slow.
	if(v>patternSpeed+5.0)
	{
		steer.throttle=0.0;
		steer.spoiler=(v>patternSpeed+15.0 ? 1.0 : 0.0);
	}
	else if(v<patternSpeed-5.0)
	{
		steer.throttle=0.8;
	}
	else
	{
		steer.throttle=0.45;
	}

	switch(phase)
	{
	default:
		break;
	case PHASE_ENTRY:
		{
			YsVec3 entry=thr+dir*(lng*0.6)+side*(radius*2.0);
			entry.SetY(fieldY+FSRVB_ENTRY_HEIGHT);
			steer.FlyTo(air,entry,3.0,15.0);
			if(v<patternSpeed*1.5)
			{
				steer.throttle=YsGreater(steer.throttle,0.6);  // Keep some speed until the break
			}
			if((entry-pos).GetSquareLengthXZ()<900.0*900.0)
			{
				SetPhase(PHASE_DOWNWIND);
			}
		}
		break;
	case PHASE_DOWNWIND:
		{
			const double latErr=Lateral(pos)-radius*2.0;
			YsVec3 want=-dir-side*YsBound(latErr/800.0,-0.5,0.5);
			want.Normalize();
			steer.TurnTowards(air,want,2.5,YsBound((fieldY+FSRVB_DOWNWIND_HEIGHT-pos.y())/8.0,-8.0,8.0));
			if(v<patternSpeed*1.25)
			{
				steer.gear=1.0;
				steer.flap=0.5;
			}
			if(Along(pos)<-finalLength)
			{
				SetPhase(PHASE_TURN);
			}
		}
		break;
	case PHASE_TURN:
		{
			// Continuous descending turn around C onto the final.
			const YsVec3 cen=thr-dir*finalLength+side*radius;
			YsVec3 r=pos-cen;
			r.SetY(0.0);
			const double d=r.GetLength();
			if(YSOK!=r.Normalize())
			{
				r=side;
			}
			YsVec3 vel;
			air.Prop().GetVelocity(vel);
			YsVec3 tangent(-r.z(),0.0,r.x());
			if(0.0>tangent*vel)
			{
				tangent=-tangent;
			}
			YsVec3 want=tangent-r*YsBound((d-radius)/radius,-0.5,0.5);
			want.Normalize();
			steer.TurnTowards(air,want,3.0,YsBound((gateY-pos.y())/6.0,-8.0,3.0));
			steer.gear=1.0;
			steer.flap=1.0;

			YsVec3 hv=vel;
			hv.SetY(0.0);
			if(YSOK==hv.Normalize() && cos(YsDegToRad(15.0))<hv*dir && fabs(Lateral(pos))<250.0)
			{
				SetPhase(PHASE_GATE);
			}
		}
		break;
	case PHASE_GATE:
	case PHASE_FAILED:
		steer.active=YSFALSE;
		break;
	}
}
