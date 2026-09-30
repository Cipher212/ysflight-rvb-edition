#include <ysclass.h>

#include "fs.h"
#include "fsutil.h"
#include "fsrvbsurvival.h"
#include "fsrvbawareness.h"
#include "fsrvbteampicture.h"

// RvB: see fsrvbsurvival.h (YSFlight RvB Edition, 2026-09-30).

static const double FSRVB_BREAK_DIST_RADAR=1800.0; // m: break instead of beaming (AIM-120 closes ~1 km/s)
static const double FSRVB_BREAK_DIST_IR=1200.0;
static const double FSRVB_FLARE_DIST_RADAR=2500.0; // m: start flaring
static const double FSRVB_FLARE_DIST_IR=1800.0;
static const double FSRVB_FLARE_INTERVAL[2]={0.3,0.5};
static const double FSRVB_BEAM_DIVE=-30.0;         // m/s vertical speed while beaming, when high enough
static const double FSRVB_BREAK_BANK=YsDegToRad(80.0);
static const double FSRVB_ODDS_RADIUS=8000.0;
static const double FSRVB_RTB_SPEED_MIN=150.0;     // m/s assumed for the trip home
static const double FSRVB_RTB_PATTERN_TIME=60.0;   // s of fuel for the pattern and landing
static const double FSRVB_RTB_FUEL_MARGIN=1.3;
static const int FSRVB_MIN_GUN_A2A=50;
static const int FSRVB_MIN_GUN_A2G=100;

////////////////////////////////////////////////////////////

static double FsRvbHeadingDifference(const YsVec3 &from,const YsVec3 &to)
{
	const double hFrom=atan2(-from.x(),from.z());
	const double hTo=atan2(-to.x(),to.z());
	double d=hTo-hFrom;
	while(YsPi<d)
	{
		d-=YsPi*2.0;
	}
	while(-YsPi>=d)
	{
		d+=YsPi*2.0;
	}
	return d;
}

double FsRvbRelativeHeading(const FsAirplane &air,const YsVec3 &dir)
{
	YsVec3 vel;
	air.Prop().GetVelocity(vel);
	if(vel.GetSquareLengthXZ()<1.0)
	{
		vel=air.GetAttitude().GetForwardVector();
	}
	return FsRvbHeadingDifference(vel,dir);
}

double FsRvbRelativeHeadingOnGround(const FsAirplane &air,const YsVec3 &dir)
{
	return FsRvbHeadingDifference(air.GetAttitude().GetForwardVector(),dir);
}

double FsRvbGroundSpeed(const FsAirplane &air)
{
	if(YsTolerance<air.prevDt)
	{
		return (air.GetPosition()-air.prevPos).GetLengthXZ()/air.prevDt;
	}
	return 0.0;
}

FsRvbSteer::FsRvbSteer()
{
	Clear();
}

void FsRvbSteer::Clear(void)
{
	active=YSFALSE;
	bank=0.0;
	useVSpeed=YSTRUE;
	vSpeed=0.0;
	g=1.0;
	gLimit=4.0;
	throttle=1.0;
	afterburner=YSFALSE;
	flare=YSFALSE;
	gear=0.0;
	spoiler=0.0;
	flap=0.0;
}

void FsRvbSteer::TurnTowards(const FsAirplane &air,const YsVec3 &dir,const double gLim,const double vSpd)
{
	const double rel=FsRvbRelativeHeading(air,dir);
	const double maxBank=YsSmaller(acos(1.0/YsGreater(gLim,1.1)),FSRVB_BREAK_BANK);
	active=YSTRUE;
	bank=YsBound(rel*3.0,-maxBank,maxBank);
	useVSpeed=YSTRUE;
	vSpeed=vSpd;
	gLimit=gLim;
}

void FsRvbSteer::FlyTo(const FsAirplane &air,const YsVec3 &pos,const double gLim,const double maxClimb)
{
	YsVec3 dir=pos-air.GetPosition();
	dir.SetY(0.0);
	const double vSpd=YsBound((pos.y()-air.GetPosition().y())/10.0,-maxClimb,maxClimb);
	TurnTowards(air,dir,gLim,vSpd);
}

////////////////////////////////////////////////////////////

FsRvbSurvival::FsRvbSurvival()
{
	defence=DEF_NONE;
	missileType=FSWEAPON_NULL;
	missileDist=0.0;
	burnRate=0.0;
	flareTimer=0.0;
	breakDir=1;
	lastFuel=-1.0;
	lastFuelClock=0.0;
}

YSBOOL FsRvbSurvival::UpdateMissileDefence(FsRvbSteer &steer,FsAirplane &air,FsSimulation *sim,const int nMissileOnMe,
    const FsRvbAwareness &aware,const FsRvbDoctrine &doc,const double minAlt,const double dt)
{
	flareTimer-=dt;
	if(0==nMissileOnMe && DEF_NONE==defence)
	{
		return YSFALSE;  // Cheap path: the team picture says nothing is chasing us
	}

	const FsWeapon *msl=sim->GetLockedOn(&air);
	if(NULL==msl)
	{
		defence=DEF_NONE;
		return YSFALSE;
	}
	if(DEF_NONE==defence && FSWEAPON_AIM120!=msl->type && YSTRUE!=aware.SpotsIrMissile(air,msl->pos,doc))
	{
		return YSFALSE;  // Unseen IR missile
	}

	missileType=msl->type;
	YsVec3 toMissile=msl->pos-air.GetPosition();
	missileDist=toMissile.GetLength();
	toMissile.SetY(0.0);
	if(YSOK!=toMissile.Normalize())
	{
		toMissile=-air.GetAttitude().GetForwardVector();
	}

	const YSBOOL radar=(FSWEAPON_AIM120==msl->type ? YSTRUE : YSFALSE);
	const double breakDist=(YSTRUE==radar ? FSRVB_BREAK_DIST_RADAR : FSRVB_BREAK_DIST_IR);
	const double flareDist=(YSTRUE==radar ? FSRVB_FLARE_DIST_RADAR : FSRVB_FLARE_DIST_IR);
	const double alt=air.GetPosition().y();

	steer.Clear();
	steer.active=YSTRUE;
	steer.throttle=1.0;
	steer.afterburner=YSTRUE;

	if(breakDist<missileDist)
	{
		// Beam: the missile 90 deg off, on whichever side needs the smaller turn.
		const YsVec3 beam(-toMissile.z(),0.0,toMissile.x());
		const YsVec3 dir=(fabs(FsRvbRelativeHeading(air,beam))<fabs(FsRvbRelativeHeading(air,-beam)) ? beam : -beam);
		double vSpd=0.0;
		if(alt>minAlt+600.0)
		{
			vSpd=FSRVB_BEAM_DIVE;
		}
		else if(alt<minAlt+200.0)
		{
			vSpd=10.0;
		}
		steer.TurnTowards(air,dir,doc.gEvade,vSpd);
		defence=DEF_BEAM;
	}
	else
	{
		if(DEF_BREAK!=defence)
		{
			// Turn into the side the missile comes from: the line of sight swings fastest for it.
			breakDir=(0.0<=FsRvbRelativeHeading(air,toMissile) ? 1 : -1);
		}
		steer.bank=breakDir*FSRVB_BREAK_BANK;
		if(alt<minAlt+300.0)
		{
			steer.useVSpeed=YSTRUE;  // Too low for a slicing break
			steer.vSpeed=5.0;
			steer.gLimit=doc.gEvade;
		}
		else
		{
			steer.useVSpeed=YSFALSE;
			steer.g=doc.gEvade;
		}
		defence=DEF_BREAK;
	}

	if(missileDist<flareDist && 0.0>=flareTimer && 0<air.Prop().GetNumWeapon(FSWEAPON_FLARE))
	{
		steer.flare=YSTRUE;
		flareTimer=FsGetRandomBetween(FSRVB_FLARE_INTERVAL[0],FSRVB_FLARE_INTERVAL[1]);
	}
	return YSTRUE;
}

YSBOOL FsRvbSurvival::OddsAgainstUs(const FsAirplane &air,const FsRvbTeamPicture &pic,const FsRvbAwareness &aware,const FsRvbDoctrine &doc) const
{
	const YsVec3 &pos=air.GetPosition();
	const double r2=FSRVB_ODDS_RADIUS*FSRVB_ODDS_RADIUS;
	double own=1.0,enemy=0.0;
	for(auto &c : pic.air)
	{
		if(c.key==air.SearchKey() || YSTRUE!=c.airborne || (c.pos-pos).GetSquareLength()>r2)
		{
			continue;
		}
		double w=(FSRVBROLE_HEAVY==c.role ? 0.25 : 1.0)*(1.0-0.5*c.damage);
		if(c.iff==air.iff)
		{
			own+=w;
		}
		else if(YSTRUE==aware.IsKnown(c.key))
		{
			YsVec3 toUs=pos-c.pos;
			if(YSOK==toUs.Normalize() && 0.5<c.fwd*toUs)  // Nose on us: a real threat
			{
				w*=1.5;
			}
			enemy+=w;
		}
	}
	if(enemy<1.0)
	{
		return YSFALSE;
	}

	enemy*=1.0+DamageFraction(air);
	double ratio=doc.bugOutRatio;
	if(YSTRUE==doc.a2a && YSTRUE!=HasAirWeapon(air,doc))
	{
		ratio*=0.5;  // Nothing left to fight with
	}
	return (enemy>own*ratio ? YSTRUE : YSFALSE);
}

void FsRvbSurvival::UpdateFuel(const FsAirplane &air,const double clock)
{
	const double fuel=TotalFuel(air);
	if(0.0<=lastFuel && 0.5<clock-lastFuelClock)
	{
		const double rate=(lastFuel-fuel)/(clock-lastFuelClock);
		if(0.0<=rate && YSTRUE!=air.Prop().GetAfterBurner())  // Plans the trip home: no afterburner, no refuelling
		{
			burnRate=(0.0>=burnRate ? rate : burnRate*0.7+rate*0.3);
		}
	}
	lastFuel=fuel;
	lastFuelClock=clock;
}

/* static */ int FsRvbSurvival::nRtb[RTB_NUMREASON]={0,0,0,0};

/* static */ const char *FsRvbSurvival::RtbReasonToStr(RTB_REASON r)
{
	switch(r)
	{
	default:
	case RTB_NONE:
		return "NONE";
	case RTB_DAMAGE:
		return "DAMAGE";
	case RTB_FUEL:
		return "FUEL";
	case RTB_WEAPONS:
		return "WEAPONS";
	}
}

FsRvbSurvival::RTB_REASON FsRvbSurvival::NeedRtb(const FsAirplane &air,const FsRvbTeamPicture &pic,const FsRvbDoctrine &doc) const
{
	const FsRvbMapInfo::Base *base=pic.map.NearestBase(air.iff,air.GetPosition());
	if(NULL==base)
	{
		return RTB_NONE;  // Nowhere to go
	}
	if(DamageFraction(air)>=doc.rtbDamage)
	{
		return RTB_DAMAGE;
	}

	const double dist=(base->pos-air.GetPosition()).GetLengthXZ();
	const double speed=YsGreater(FSRVB_RTB_SPEED_MIN,air.Prop().GetEstimatedCruiseSpeed());
	const double need=burnRate*(dist/speed+FSRVB_RTB_PATTERN_TIME)*FSRVB_RTB_FUEL_MARGIN+
	                  doc.reserveFuel*air.Prop().GetMaxFuelLoad();
	if(TotalFuel(air)<need)
	{
		return RTB_FUEL;
	}

	const YSBOOL air2air=HasAirWeapon(air,doc);
	const YSBOOL air2gnd=HasGroundWeapon(air,doc);
	YSBOOL empty=YSFALSE;
	if(YSTRUE==doc.a2a && YSTRUE==doc.a2g)
	{
		empty=(YSTRUE!=air2air && YSTRUE!=air2gnd ? YSTRUE : YSFALSE);
	}
	else if(YSTRUE==doc.a2a)
	{
		empty=(YSTRUE!=air2air ? YSTRUE : YSFALSE);
	}
	else if(YSTRUE==doc.a2g)
	{
		empty=(YSTRUE!=air2gnd ? YSTRUE : YSFALSE);
	}
	return (YSTRUE==empty ? RTB_WEAPONS : RTB_NONE);
}

/* static */ YSBOOL FsRvbSurvival::HasAirWeapon(const FsAirplane &air,const FsRvbDoctrine &doc)
{
	if((0!=(doc.aamMask&FSRVBAAM_AIM9) && 0<air.Prop().GetNumWeapon(FSWEAPON_AIM9)) ||
	   (0!=(doc.aamMask&FSRVBAAM_AIM9X) && 0<air.Prop().GetNumWeapon(FSWEAPON_AIM9X)) ||
	   (0!=(doc.aamMask&FSRVBAAM_AIM120) && 0<air.Prop().GetNumWeapon(FSWEAPON_AIM120)))
	{
		return YSTRUE;
	}
	if(0.0<doc.gunRange && FSRVB_MIN_GUN_A2A<air.Prop().GetNumWeapon(FSWEAPON_GUN))
	{
		return YSTRUE;
	}
	return YSFALSE;
}

/* static */ YSBOOL FsRvbSurvival::HasGroundWeapon(const FsAirplane &air,const FsRvbDoctrine &doc)
{
	for(int i=0; i<4 && FSWEAPON_NULL!=doc.a2gWeapon[i]; ++i)
	{
		if(0<air.Prop().GetNumWeapon(doc.a2gWeapon[i]))
		{
			return YSTRUE;
		}
	}
	if(YSTRUE==doc.a2gGun && FSRVB_MIN_GUN_A2G<air.Prop().GetNumWeapon(FSWEAPON_GUN))
	{
		return YSTRUE;
	}
	return YSFALSE;
}

/* static */ double FsRvbSurvival::TotalFuel(const FsAirplane &air)
{
	return air.Prop().GetFuelLeft()+air.Prop().GetExternalFuelLeft();
}

/* static */ double FsRvbSurvival::DamageFraction(const FsAirplane &air)
{
	const int defDmg=air.GetDefaultDamageTolerance();
	if(0<defDmg)
	{
		return YsBound(1.0-(double)air.Prop().GetDamageTolerance()/(double)defDmg,0.0,1.0);
	}
	return 0.0;
}

/* static */ void FsRvbSurvival::DropTanks(FsAirplane &air,FsSimulation *sim)
{
	for(int i=0; i<8 && 0<air.Prop().GetNumWeapon(FSWEAPON_FUELTANK); ++i)
	{
		YSBOOL blockedByBombBay;
		air.Prop().FireWeapon(blockedByBombBay,sim,sim->GetClock(),sim->GetWeaponStore(),&air,FSWEAPON_FUELTANK);
	}
}

/* static */ void FsRvbSurvival::DropBombs(FsAirplane &air)
{
	air.Prop().SetNumWeapon(FSWEAPON_BOMB,0);
	air.Prop().SetNumWeapon(FSWEAPON_BOMB250,0);
	air.Prop().SetNumWeapon(FSWEAPON_BOMB500HD,0);
}
