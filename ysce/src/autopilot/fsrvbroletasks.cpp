#include <ysclass.h>

#include "fs.h"
#include "fsutil.h"
#include "fsrvbroletasks.h"
#include "fsrvbteampicture.h"
#include "fsrvbawareness.h"

// RvB: see fsrvbroletasks.h (YSFlight RvB Edition, 2026-09-30).

static const double FSRVB_HUNTING_OURS=0.7;   // Score factor: it is attacking one of us
static const double FSRVB_ANSWER_CALL=0.4;    // Score factor: a team mate called for help against it
static const double FSRVB_CROWDING=0.5;       // Score penalty per team mate already on it
static const double FSRVB_UNAWARE=0.7;        // STEALTH: prefers enemies not looking its way
static const double FSRVB_GND_PRIMARY=0.6;
static const double FSRVB_GND_DEFENDER=0.3;   // Penalty per SAM/AAA covering a ground target
static const double FSRVB_GND_STICK=0.5;
static const double FSRVB_STEALTH_SAM=0.4;    // STEALTH: stand-off AGM-65 on air defences
static const double FSRVB_CAS_FRONT=2.0;      // CAS: penalty for targets far from the front line
static const double FSRVB_EDGE_ORBIT[2]={15000.0,20000.0};

static double FsRvbSlotFraction(int slot)
{
	return (double)(slot%7)/6.0;
}

/* static */ YSHASHKEY FsRvbRoleTasks::ChooseAirTarget(const FsAirplane &air,const FsRvbTeamPicture &pic,const FsRvbAwareness &aware,
    const FsRvbDoctrine &doc,YSHASHKEY current,const YsVec3 &stationPos)
{
	const YsVec3 &pos=air.GetPosition();
	const YsVec3 &ref=(FSRVBSTATION_FLANK_CAP==doc.station ? stationPos : pos);

	YSHASHKEY best=YSNULLHASHKEY;
	double bestScore=YsInfinity;
	for(auto &c : pic.air)
	{
		if(c.iff==air.iff || YSTRUE!=c.airborne)
		{
			continue;
		}
		const FsRvbAwareness::Call *call=aware.FindCallAbout(c.key);
		const YSBOOL answering=(NULL!=call && YSTRUE==call->willHelp ? YSTRUE : YSFALSE);
		if(YSTRUE!=aware.IsKnown(c.key) && YSTRUE!=answering)
		{
			continue;
		}

		const double d=(c.pos-pos).GetLength();
		if(YSTRUE==answering)
		{
			if(doc.helpRange<d)
			{
				continue;
			}
		}
		else if(doc.engageRange*doc.engageRange<(c.pos-ref).GetSquareLength())
		{
			continue;
		}

		double score=d;
		if(c.key==current)
		{
			score*=1.0-doc.stickiness;
		}
		const FsRvbTeamPicture::AirContact *victim=pic.FindAir(c.engagedKey);
		if(NULL!=victim && victim->iff==air.iff)
		{
			score*=FSRVB_HUNTING_OURS;
		}
		if(YSTRUE==answering)
		{
			score*=FSRVB_ANSWER_CALL;
		}
		score*=1.0+FSRVB_CROWDING*(double)pic.CountEngaging(air.iff,c.key,air.SearchKey());
		if(FSRVBROLE_STEALTH==doc.role)
		{
			YsVec3 toMe=pos-c.pos;
			if(YSOK==toMe.Normalize() && 0.0>c.fwd*toMe)
			{
				score*=FSRVB_UNAWARE;
			}
		}

		if(score<bestScore)
		{
			best=c.key;
			bestScore=score;
		}
	}
	return best;
}

/* static */ YSHASHKEY FsRvbRoleTasks::ChooseGroundTarget(const FsAirplane &air,FsSimulation *sim,const FsRvbTeamPicture &pic,
    const FsRvbDoctrine &doc,YSHASHKEY current)
{
	const YsVec3 &pos=air.GetPosition();
	YSHASHKEY best=YSNULLHASHKEY;
	double bestScore=YsInfinity;
	for(auto &g : pic.map.gnd)
	{
		if(g.iff==air.iff || 0>g.iff || FS_IFF_NEUTRAL<=g.iff || YSTRUE!=pic.map.teamValid[g.iff])
		{
			continue;  // Own objects, and objects of IFFs without aircraft (e.g. the pirates)
		}
		const FsGround *gnd=sim->FindGround(g.key);
		if(NULL==gnd || YSTRUE!=gnd->IsAlive())
		{
			continue;
		}

		double score=(g.pos-pos).GetLengthXZ();
		score*=(YSTRUE==g.primary ? FSRVB_GND_PRIMARY : 1.0);
		score*=1.0+FSRVB_GND_DEFENDER*(double)g.nDefender;
		if(FSRVBROLE_CAS==doc.role)
		{
			score*=1.0+FSRVB_CAS_FRONT*fabs(pic.map.OwnSideness(air.iff,g.pos));
		}
		else if(FSRVBROLE_STEALTH==doc.role)
		{
			score*=(0.0<g.threatRange ? FSRVB_STEALTH_SAM : 1.5);
		}
		if(g.key==current)
		{
			score*=FSRVB_GND_STICK;
		}
		score*=FsGetRandomBetween(0.85,1.15);  // Spread aircraft over similar targets

		if(score<bestScore)
		{
			best=g.key;
			bestScore=score;
		}
	}
	return best;
}

/* static */ int FsRvbRoleTasks::ChooseRunway(YsVec3 &runStart,YsVec3 &runEnd,const FsAirplane &air,const FsRvbTeamPicture &pic,int runCount)
{
	// The longest enemy runways, taken in turn over successive sorties (at most the three longest).
	YsArray <int,16> enemyRwy;
	for(int i=0; i<(int)pic.map.runway.GetN(); ++i)
	{
		const FSIFF iff=pic.map.runway[i].iff;
		if(iff!=air.iff && 0<=iff && iff<FS_IFF_NEUTRAL && YSTRUE==pic.map.teamValid[iff])
		{
			enemyRwy.Append(i);
		}
	}
	if(0==enemyRwy.GetN())
	{
		return -1;
	}
	for(YSSIZE_T i=0; i<enemyRwy.GetN(); ++i)  // Longest first (a handful of runways)
	{
		for(YSSIZE_T j=i+1; j<enemyRwy.GetN(); ++j)
		{
			const auto &a=pic.map.runway[enemyRwy[i]];
			const auto &b=pic.map.runway[enemyRwy[j]];
			if((a.end[1]-a.end[0]).GetSquareLength()<(b.end[1]-b.end[0]).GetSquareLength())
			{
				YsSwapSomething(enemyRwy[i],enemyRwy[j]);
			}
		}
	}

	const int pick=enemyRwy[runCount%YsSmaller<int>(3,(int)enemyRwy.GetN())];
	const auto &rwy=pic.map.runway[pick];
	if(pic.map.OwnSideness(air.iff,rwy.end[0])>=pic.map.OwnSideness(air.iff,rwy.end[1]))
	{
		runStart=rwy.end[0];
		runEnd=rwy.end[1];
	}
	else
	{
		runStart=rwy.end[1];
		runEnd=rwy.end[0];
	}
	return pick;
}

/* static */ YsVec3 FsRvbRoleTasks::StationPosition(const FsAirplane &air,const FsRvbTeamPicture &pic,const FsRvbDoctrine &doc,int slot)
{
	const FsRvbMapInfo &map=pic.map;
	const YsVec3 ownDir=map.OwnSideDir(air.iff);
	const double ownDepth=YsGreater(5000.0,(0.0<ownDir*map.axis ? map.axisExtent[1] : -map.axisExtent[0]));
	const double latMid=(map.lateralExtent[0]+map.lateralExtent[1])/2.0;
	const double latHalf=YsGreater(5000.0,(map.lateralExtent[1]-map.lateralExtent[0])/2.0);
	const double f=FsRvbSlotFraction(slot);
	const double alt=doc.stationAlt[0]+(doc.stationAlt[1]-doc.stationAlt[0])*f;

	double along=0.0,across=latMid;
	switch(doc.station)
	{
	default:
	case FSRVBSTATION_FRONT:
		along=5000.0;
		across=latMid+latHalf*0.6*(f*2.0-1.0);
		break;
	case FSRVBSTATION_CENTER:
		along=2000.0*(f*2.0-1.0);
		across=latMid+2000.0*(f*2.0-1.0);
		break;
	case FSRVBSTATION_FLANK_CAP:
		switch(slot%3)
		{
		default:
		case 0:
			along=ownDepth*0.4;
			across=latMid-latHalf*0.75;
			break;
		case 1:
			along=ownDepth*0.4;
			across=latMid+latHalf*0.75;
			break;
		case 2:
			along=ownDepth*0.75;
			across=latMid;
			break;
		}
		break;
	case FSRVBSTATION_EDGE_ORBIT:
		along=0.0;
		across=latMid+(0==slot%2 ? 1.0 : -1.0)*YsBound(latHalf,FSRVB_EDGE_ORBIT[0],FSRVB_EDGE_ORBIT[1]);
		break;
	case FSRVBSTATION_OWN_REAR:
		along=ownDepth*0.6;
		across=latMid;
		break;
	}
	return map.MakePosition(air.iff,along,across,alt);
}

/* static */ double FsRvbRoleTasks::NearestKnownEnemy(const FsAirplane &air,const FsRvbTeamPicture &pic,const FsRvbAwareness &aware)
{
	double best=YsInfinity;
	for(auto &c : pic.air)
	{
		if(c.iff!=air.iff && YSTRUE==c.airborne && YSTRUE==aware.IsKnown(c.key))
		{
			best=YsSmaller(best,(c.pos-air.GetPosition()).GetLength());
		}
	}
	return best;
}
