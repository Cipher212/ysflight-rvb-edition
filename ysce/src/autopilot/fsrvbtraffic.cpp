#include <ysclass.h>

#include "fs.h"
#include "fsrvbtraffic.h"
#include "fsrvbairfieldplan.h"
#include "fsrvbarrival.h"

// RvB: see fsrvbtraffic.h (YSFlight RvB Edition, 2026-10-01).

static const double FSRVB_FOLLOW_LOOK=150.0;    // m of my route ahead that is checked
static const double FSRVB_FOLLOW_STEP=4.0;      // m between route samples
static const double FSRVB_FOLLOW_CORRIDOR=18.0; // m either side of the route centre
static const double FSRVB_FOLLOW_GAP=30.0;      // m nose to nose kept when stopped behind someone

class FsRvbZone
{
public:
	const FsRvbAirfieldPlan *plan;
	YsString name;
	YSHASHKEY holder;
	int uses;
};

static YsArray <FsRvbZone> &FsRvbZoneList(void)
{
	static YsArray <FsRvbZone> lst;
	return lst;
}

static FsRvbZone *FsRvbFindZone(const FsRvbAirfieldPlan *plan,const char zone[])
{
	for(auto &z : FsRvbZoneList())
	{
		if(z.plan==plan && 0==z.name.STRCMP(zone))
		{
			return &z;
		}
	}
	return NULL;
}

// YSFlight RvB Edition, 2026-10-03: airborne holding stack
class FsRvbHoldEntry
{
public:
	const FsRvbAirfieldPlan *plan;
	YSHASHKEY who;
};

static YsArray <FsRvbHoldEntry> &FsRvbHoldStack(void)
{
	static YsArray <FsRvbHoldEntry> stack;
	return stack;
}

static double lastPurgeTime=-1.0;

/* static */ void FsRvbTraffic::Reset(void)
{
	FsRvbZoneList().Clear();
	FsRvbHoldStack().Clear();
	lastPurgeTime=-1.0;
}

/* static */ YSBOOL FsRvbTraffic::Book(const FsRvbAirfieldPlan *plan,const char zone[],YSHASHKEY who)
{
	FsRvbZone *z=FsRvbFindZone(plan,zone);
	if(NULL==z)
	{
		FsRvbZoneList().Increment();
		z=&FsRvbZoneList().Last();
		z->plan=plan;
		z->name.Set(zone);
		z->holder=YSNULLHASHKEY;
		z->uses=0;
	}
	if(YSNULLHASHKEY==z->holder || who==z->holder)
	{
		z->uses+=(who!=z->holder ? 1 : 0);
		z->holder=who;
		return YSTRUE;
	}
	return YSFALSE;
}

/* static */ void FsRvbTraffic::Release(const FsRvbAirfieldPlan *plan,const char zone[],YSHASHKEY who)
{
	FsRvbZone *z=FsRvbFindZone(plan,zone);
	if(NULL!=z && who==z->holder)
	{
		z->holder=YSNULLHASHKEY;
	}
}

/* static */ void FsRvbTraffic::ReleaseAll(YSHASHKEY who)
{
	for(auto &z : FsRvbZoneList())
	{
		if(who==z.holder)
		{
			z.holder=YSNULLHASHKEY;
		}
	}
	for(int i=(int)FsRvbHoldStack().GetN()-1; 0<=i; --i)
	{
		if(who==FsRvbHoldStack()[i].who)
		{
			FsRvbHoldStack().Delete(i);
		}
	}
}

/* static */ int FsRvbTraffic::JoinHold(const FsRvbAirfieldPlan *plan,YSHASHKEY who)
{
	int level=0;
	for(int i=0; i<FsRvbHoldStack().GetN(); ++i)
	{
		if(FsRvbHoldStack()[i].plan==plan)
		{
			if(FsRvbHoldStack()[i].who==who)
			{
				return level;
			}
			++level;
		}
	}
	FsRvbHoldEntry entry;
	entry.plan=plan;
	entry.who=who;
	FsRvbHoldStack().Append(entry);
	return level;
}

/* static */ void FsRvbTraffic::LeaveHold(const FsRvbAirfieldPlan *plan,YSHASHKEY who)
{
	for(int i=0; i<FsRvbHoldStack().GetN(); ++i)
	{
		if(FsRvbHoldStack()[i].plan==plan && FsRvbHoldStack()[i].who==who)
		{
			FsRvbHoldStack().Delete(i);
			break;
		}
	}
}

/* static */ int FsRvbTraffic::GetHoldStackLevel(const FsRvbAirfieldPlan *plan,YSHASHKEY who)
{
	int level=0;
	for(int i=0; i<FsRvbHoldStack().GetN(); ++i)
	{
		if(FsRvbHoldStack()[i].plan==plan)
		{
			if(FsRvbHoldStack()[i].who==who)
			{
				return level;
			}
			++level;
		}
	}
	return -1;
}

/* static */ int FsRvbTraffic::NumHolding(const FsRvbAirfieldPlan *plan)
{
	int count=0;
	for(int i=0; i<FsRvbHoldStack().GetN(); ++i)
	{
		if(FsRvbHoldStack()[i].plan==plan)
		{
			++count;
		}
	}
	return count;
}

/* static */ YSBOOL FsRvbTraffic::IsFree(const FsRvbAirfieldPlan *plan,const char zone[],YSHASHKEY askedBy)
{
	const FsRvbZone *z=FsRvbFindZone(plan,zone);
	return (NULL==z || YSNULLHASHKEY==z->holder || askedBy==z->holder ? YSTRUE : YSFALSE);
}

/* static */ YSBOOL FsRvbTraffic::HasClearance(const FsRvbAirfieldPlan *plan,const char zone[],YSHASHKEY who)
{
	const FsRvbZone *z=FsRvbFindZone(plan,zone);
	return (NULL!=z && who==z->holder ? YSTRUE : YSFALSE);
}

/* static */ void FsRvbTraffic::PurgeDead(FsSimulation *sim)
{
	if(NULL==sim)
	{
		return;
	}
	const double curTime=sim->CurrentTime();
	if(curTime==lastPurgeTime && curTime>=0.0)
	{
		return; // Bounded: at most one simulation-wide scan per tick across all callers
	}
	lastPurgeTime=curTime;
	for(auto &z : FsRvbZoneList())
	{
		if(YSNULLHASHKEY!=z.holder)
		{
			FsAirplane *air=sim->FindAirplane(z.holder);
			if(NULL==air || YSTRUE!=air->IsAlive())
			{
				z.holder=YSNULLHASHKEY;
			}
		}
	}
	for(int i=(int)FsRvbHoldStack().GetN()-1; 0<=i; --i)
	{
		FsAirplane *air=sim->FindAirplane(FsRvbHoldStack()[i].who);
		if(NULL==air || YSTRUE!=air->IsAlive())
		{
			FsRvbHoldStack().Delete(i);
		}
	}
}

/* static */ int FsRvbTraffic::Uses(const FsRvbAirfieldPlan *plan,const char zone[])
{
	const FsRvbZone *z=FsRvbFindZone(plan,zone);
	return (NULL!=z ? z->uses : 0);
}

/* static */ double FsRvbTraffic::FollowLimit(const FsAirplane &me,FsSimulation *sim,const FsRvbPath &route,const double sMe,
                                              const double decel)
{
	// Everything on the ground near my route ahead counts, AI or human (ground traffic is a few jets: O(N) is fine).
	double gap=YsInfinity;
	for(FsAirplane *other=NULL; NULL!=(other=sim->FindNextAirplane(other)); )
	{
		if(other==&me || YSTRUE!=other->IsAlive() || YSTRUE!=other->Prop().IsOnGround() ||
		   (other->GetPosition()-me.GetPosition()).GetSquareLengthXZ()>YsSqr(FSRVB_FOLLOW_LOOK+40.0))
		{
			continue;
		}
		const YsVec2 q(other->GetPosition().x(),other->GetPosition().z());
		for(double d=FSRVB_FOLLOW_STEP; d<=FSRVB_FOLLOW_LOOK; d+=FSRVB_FOLLOW_STEP)
		{
			if((route.PointAt(sMe+d)-q).GetSquareLength()<YsSqr(FSRVB_FOLLOW_CORRIDOR))
			{
				gap=YsSmaller(gap,d);
				break;
			}
		}
	}
	if(YsInfinity<=gap)
	{
		return YsInfinity;
	}
	return sqrt(2.0*decel*YsGreater(0.0,gap-FSRVB_FOLLOW_GAP));
}

/* static */ YSBOOL FsRvbTraffic::ArrivalWithin(FsSimulation *sim,const FsRvbAirfieldPlan *plan,const double dist,const FsAirplane &me)
{
	for(FsAirplane *other=NULL; NULL!=(other=sim->FindNextAirplane(other)); )
	{
		if(other==&me || YSTRUE!=other->IsAlive())
		{
			continue;
		}
		const FsRvbArrival *ap=dynamic_cast<const FsRvbArrival *>(other->GetAutopilot());
		if(NULL==ap || ap->GetPlan()!=plan)
		{
			continue;
		}
		if((FsRvbArrival::PHASE_APPROACH==ap->GetPhase() || FsRvbArrival::PHASE_FLARE==ap->GetPhase()) &&
		   (other->GetPosition()-plan->OnCentreLine(plan->tdMedian)).GetLengthXZ()<dist)
		{
			return YSTRUE;
		}
	}
	return YSFALSE;
}
