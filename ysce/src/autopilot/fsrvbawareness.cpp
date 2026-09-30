#include <ysclass.h>

#include "fs.h"
#include "fsutil.h"
#include "fsrvbawareness.h"
#include "fsrvbteampicture.h"

// RvB: see fsrvbawareness.h for the model (YSFlight RvB Edition, 2026-09-30).

static const double FSRVB_FRONT_HALF_ANGLE=YsDegToRad(60.0);
static const double FSRVB_REAR_HALF_ANGLE=YsDegToRad(60.0);   // i.e. more than 120 deg off the nose

static const double FSRVB_SIDE_CERTAIN=1500.0;  // m, x awareSkill
static const double FSRVB_SIDE_RANGE=5000.0;    // m
static const double FSRVB_SIDE_RATE=0.6;        // per second at the certain range, x awareSkill
static const double FSRVB_REAR_CERTAIN=300.0;   // m, x awareSkill
static const double FSRVB_REAR_RANGE=2000.0;    // m
static const double FSRVB_REAR_RATE=0.12;       // per second at the certain range, x awareSkill
static const double FSRVB_KEEP_FACTOR=1.25;
static const double FSRVB_MEMORY=6.0;           // s
static const double FSRVB_HIT_REVEAL_RANGE=1500.0;

static const double FSRVB_CALL_RATE=0.5;        // per second
static const double FSRVB_CALL_ERROR=0.1;       // Fraction of the distance
static const double FSRVB_CALL_TIMEOUT=15.0;    // s

static const double FSRVB_IR_SPOT_FRONT=3000.0; // m, x awareSkill
static const double FSRVB_IR_SPOT_SIDE=2000.0;
static const double FSRVB_IR_SPOT_REAR=1000.0;

void FsRvbAwareness::Clear(void)
{
	known.Clear();
	calls.Clear();
}

/* static */ FsRvbAwareness::ASPECT FsRvbAwareness::GetAspect(const FsAirplane &air,const YsVec3 &pos)
{
	YsVec3 rel=pos-air.GetPosition();
	if(YSOK!=rel.Normalize())
	{
		return ASPECT_FRONT;
	}
	const double c=rel*air.GetAttitude().GetForwardVector();
	if(c>=cos(FSRVB_FRONT_HALF_ANGLE))
	{
		return ASPECT_FRONT;
	}
	else if(c<=-cos(FSRVB_REAR_HALF_ANGLE))
	{
		return ASPECT_REAR;
	}
	return ASPECT_SIDE;
}

YSBOOL FsRvbAwareness::IsKnown(YSHASHKEY key) const
{
	for(auto &k : known)
	{
		if(k.key==key)
		{
			return YSTRUE;
		}
	}
	return YSFALSE;
}

const FsRvbAwareness::Call *FsRvbAwareness::FindCallAbout(YSHASHKEY attackerKey) const
{
	for(auto &call : calls)
	{
		if(YSNULLHASHKEY!=attackerKey && call.attackerKey==attackerKey)
		{
			return &call;
		}
	}
	return NULL;
}

void FsRvbAwareness::Remember(YSHASHKEY key,const double clock)
{
	for(auto &k : known)
	{
		if(k.key==key)
		{
			k.lastSeen=clock;
			return;
		}
	}
	known.Increment();
	known.Last().key=key;
	known.Last().lastSeen=clock;
}

void FsRvbAwareness::Forget(const double clock)
{
	for(auto i=known.GetN()-1; 0<=i; --i)
	{
		if(FSRVB_MEMORY<clock-known[i].lastSeen)
		{
			known.DeleteBySwapping(i);
		}
	}
	for(auto i=calls.GetN()-1; 0<=i; --i)
	{
		if(FSRVB_CALL_TIMEOUT<clock-calls[i].heardAt)
		{
			calls.DeleteBySwapping(i);
		}
	}
}

void FsRvbAwareness::Scan(const FsAirplane &air,const FsRvbTeamPicture &pic,const FsRvbDoctrine &doc,
                          const double clock,const double scanDt,const YSBOOL gotHit)
{
	const YsVec3 &pos=air.GetPosition();
	const double skill=doc.awareSkill;

	YSHASHKEY hitBy=YSNULLHASHKEY;
	double hitByDist=FSRVB_HIT_REVEAL_RANGE;

	for(auto &c : pic.air)
	{
		if(c.iff==air.iff || YSTRUE!=c.airborne)
		{
			continue;
		}
		const double d=(c.pos-pos).GetLength();
		if(YSTRUE==gotHit && d<hitByDist)
		{
			hitBy=c.key;
			hitByDist=d;
		}

		double certain,outer,rate;
		switch(GetAspect(air,c.pos))
		{
		default:
		case ASPECT_FRONT:
			certain=doc.radarRange;
			outer=doc.radarRange;
			rate=0.0;
			break;
		case ASPECT_SIDE:
			certain=FSRVB_SIDE_CERTAIN*skill;
			outer=FSRVB_SIDE_RANGE;
			rate=FSRVB_SIDE_RATE*skill*YsBound((outer-d)/(outer-certain),0.0,1.0);
			break;
		case ASPECT_REAR:
			certain=FSRVB_REAR_CERTAIN*skill;
			outer=FSRVB_REAR_RANGE;
			rate=FSRVB_REAR_RATE*skill*YsBound((outer-d)/(outer-certain),0.0,1.0);
			break;
		}

		if(YSTRUE==IsKnown(c.key))
		{
			if(d<YsGreater(certain,outer)*FSRVB_KEEP_FACTOR)
			{
				Remember(c.key,clock);
			}
		}
		else if(d<certain)
		{
			Remember(c.key,clock);
		}
		else if(0.0<rate && FsGetRandomBetween(0.0,1.0)<1.0-exp(-rate*scanDt))
		{
			Remember(c.key,clock);
		}
	}
	if(YSNULLHASHKEY!=hitBy)
	{
		Remember(hitBy,clock);
	}

	// Radio: team mates in trouble.
	if(0.0<doc.helpWillingness)
	{
		for(auto &f : pic.air)
		{
			if(f.iff!=air.iff || f.key==air.SearchKey() ||
			   (0==f.nMissileOnIt && YSNULLHASHKEY==f.attackerKey) ||
			   (f.pos-pos).GetSquareLength()>doc.helpRange*doc.helpRange)
			{
				continue;
			}
			YSBOOL already=YSFALSE;
			for(auto &call : calls)
			{
				if(call.friendKey==f.key)
				{
					already=YSTRUE;
					break;
				}
			}
			if(YSTRUE==already || FsGetRandomBetween(0.0,1.0)>=1.0-exp(-FSRVB_CALL_RATE*scanDt))
			{
				continue;
			}

			const FsRvbTeamPicture::AirContact *attacker=pic.FindAir(f.attackerKey);
			const YsVec3 where=(NULL!=attacker ? attacker->pos : f.pos);
			const double err=FSRVB_CALL_ERROR*(where-pos).GetLength();
			YsVec3 rough=where;
			rough.AddX(FsGetRandomBetween(-err,err));
			rough.AddZ(FsGetRandomBetween(-err,err));

			calls.Increment();
			calls.Last().friendKey=f.key;
			calls.Last().attackerKey=f.attackerKey;
			calls.Last().roughPos=rough;
			calls.Last().heardAt=clock;
			calls.Last().willHelp=(FsGetRandomBetween(0.0,1.0)<doc.helpWillingness ? YSTRUE : YSFALSE);
		}
	}

	Forget(clock);
}

YSBOOL FsRvbAwareness::SpotsIrMissile(const FsAirplane &air,const YsVec3 &missilePos,const FsRvbDoctrine &doc) const
{
	double range;
	switch(GetAspect(air,missilePos))
	{
	default:
	case ASPECT_FRONT:
		range=FSRVB_IR_SPOT_FRONT;
		break;
	case ASPECT_SIDE:
		range=FSRVB_IR_SPOT_SIDE;
		break;
	case ASPECT_REAR:
		range=FSRVB_IR_SPOT_REAR;
		break;
	}
	range*=doc.awareSkill;
	return ((missilePos-air.GetPosition()).GetSquareLength()<range*range ? YSTRUE : YSFALSE);
}

YSHASHKEY FsRvbAwareness::KnownThreatBehind(const FsAirplane &air,const FsRvbTeamPicture &pic,const double range) const
{
	YSHASHKEY best=YSNULLHASHKEY;
	double bestD2=range*range;
	for(auto &k : known)
	{
		const FsRvbTeamPicture::AirContact *c=pic.FindAir(k.key);
		if(NULL==c || ASPECT_FRONT==GetAspect(air,c->pos))
		{
			continue;
		}
		YsVec3 toUs=air.GetPosition()-c->pos;
		const double d2=toUs.GetSquareLength();
		if(d2<bestD2 && YSOK==toUs.Normalize() && 0.7<c->fwd*toUs)  // Its nose is on us
		{
			best=c->key;
			bestD2=d2;
		}
	}
	return best;
}
