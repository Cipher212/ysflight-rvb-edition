#include <ysclass.h>

#include "fs.h"
#include "fsrvbteampicture.h"
#include "fsrvbtacticalautopilot.h"

// RvB: see fsrvbteampicture.h (YSFlight RvB Edition, 2026-09-30).

static const double FSRVB_PICTURE_REFRESH=0.25;  // s of sim time between refreshes
static const double FSRVB_ATTACKER_RANGE=3000.0; // m: an enemy engaging a jet from this close is "on" it

FsRvbTeamPicture::FsRvbTeamPicture()
{
	simCache=NULL;
	lastRefresh=-1.0;
	nRefresh=0;
}

static FsRvbTeamPicture *&FsRvbTeamPictureInstance(void)
{
	static FsRvbTeamPicture *pic=NULL;
	return pic;
}

/* static */ FsRvbTeamPicture &FsRvbTeamPicture::Get(FsSimulation *sim)
{
	FsRvbTeamPicture *&pic=FsRvbTeamPictureInstance();
	if(NULL==pic)
	{
		pic=new FsRvbTeamPicture;
	}
	if(pic->simCache!=sim)
	{
		pic->simCache=sim;
		pic->map=FsRvbMapInfo();
		pic->air.Clear();
		pic->lastRefresh=-1.0;
	}

	const double t=sim->GetClock();
	if(YSTRUE!=pic->map.valid)
	{
		pic->map.Build(sim);
	}
	if(0.0>pic->lastRefresh || t<pic->lastRefresh || FSRVB_PICTURE_REFRESH<=t-pic->lastRefresh)
	{
		pic->Refresh(sim);
		pic->lastRefresh=t;
	}
	return *pic;
}

/* static */ void FsRvbTeamPicture::Reset(void)
{
	FsRvbTeamPicture *&pic=FsRvbTeamPictureInstance();
	if(NULL!=pic)
	{
		pic->simCache=NULL;
		pic->nRefresh=0;
	}
}

void FsRvbTeamPicture::Refresh(FsSimulation *sim)
{
	++nRefresh;
	map.Refresh(sim);

	air.Clear();
	const FsAirplane *player=sim->GetPlayerAirplane();
	for(FsAirplane *a=NULL; NULL!=(a=sim->FindNextAirplane(a)); )
	{
		if(YSTRUE!=a->IsAlive())
		{
			continue;
		}
		air.Increment();
		AirContact &c=air.Last();
		c.key=a->SearchKey();
		c.iff=a->iff;
		c.pos=a->GetPosition();
		a->Prop().GetVelocity(c.vel);
		c.fwd=a->GetAttitude().GetForwardVector();
		c.airborne=(YSTRUE==a->Prop().IsOnGround() ? YSFALSE : YSTRUE);
		c.isPlayer=(a==player ? YSTRUE : YSFALSE);
		c.nMissileOnIt=0;
		c.attackerKey=YSNULLHASHKEY;

		const int defDmg=a->GetDefaultDamageTolerance();
		c.damage=(0<defDmg ? 1.0-(double)a->Prop().GetDamageTolerance()/(double)defDmg : 0.0);

		const FsRvbTacticalAutopilot *rvb=dynamic_cast <const FsRvbTacticalAutopilot *>(a->GetAutopilot());
		if(NULL!=rvb)
		{
			c.role=rvb->GetRole();
			c.engagedKey=rvb->GetEngagedAirKey();
		}
		else
		{
			c.role=FsRvbRoleTable::GetRole(a->GetIdentifier());
			c.engagedKey=a->Prop().GetAirTargetKey();
		}
	}

	// Who is on whom (N is at most ~64, refreshed 4 times a second).
	for(auto &victim : air)
	{
		for(auto &enemy : air)
		{
			if(enemy.iff!=victim.iff && enemy.engagedKey==victim.key &&
			   (enemy.pos-victim.pos).GetSquareLength()<FSRVB_ATTACKER_RANGE*FSRVB_ATTACKER_RANGE)
			{
				victim.attackerKey=enemy.key;
				break;
			}
		}
	}

	// Guided missiles in the air, counted on their targets.
	const FsWeaponHolder &wpnStore=sim->GetWeaponStore();
	for(const FsWeapon *wpn=NULL; NULL!=(wpn=wpnStore.FindNextActiveWeapon(wpn)); )
	{
		if(NULL!=wpn->target && YsTolerance<wpn->lifeRemain &&
		   (FSWEAPON_AIM9==wpn->type || FSWEAPON_AIM9X==wpn->type || FSWEAPON_AIM120==wpn->type))
		{
			const YSHASHKEY tgtKey=FsExistence::GetSearchKey(wpn->target);
			for(auto &c : air)
			{
				if(c.key==tgtKey)
				{
					++c.nMissileOnIt;
					break;
				}
			}
		}
	}
}

const FsRvbTeamPicture::AirContact *FsRvbTeamPicture::FindAir(YSHASHKEY key) const
{
	for(auto &c : air)
	{
		if(c.key==key)
		{
			return &c;
		}
	}
	return NULL;
}

int FsRvbTeamPicture::CountEngaging(FSIFF iff,YSHASHKEY targetKey,YSHASHKEY exceptKey) const
{
	int n=0;
	for(auto &c : air)
	{
		if(c.iff==iff && c.key!=exceptKey && c.engagedKey==targetKey)
		{
			++n;
		}
	}
	return n;
}

const FsRvbTeamPicture::AirContact *FsRvbTeamPicture::NearestEnemy(double &dist,FSIFF iff,const YsVec3 &pos,const double maxDist) const
{
	const AirContact *best=NULL;
	double bestD2=maxDist*maxDist;
	for(auto &c : air)
	{
		const double d2=(c.pos-pos).GetSquareLength();
		if(c.iff!=iff && YSTRUE==c.airborne && d2<bestD2)
		{
			best=&c;
			bestD2=d2;
		}
	}
	dist=(NULL!=best ? sqrt(bestD2) : maxDist);
	return best;
}
