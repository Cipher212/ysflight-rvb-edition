#include <ysclass.h>

#include "fs.h"
#include "fsrvbmapinfo.h"

// RvB: see fsrvbmapinfo.h (YSFlight RvB Edition, 2026-09-30).

static const double FSRVB_AREA_MARGIN=5000.0;     // Game area = objects and bases + this margin
static const double FSRVB_OWNER_RADIUS=3000.0;    // Ground objects this close decide who owns an airport
static const double FSRVB_RUNWAY_BASE_DIST=6000.0;
static const double FSRVB_STP_RUNWAY_LENGTH=2000.0;// m of runway assumed ahead of a runway start spot
static const double FSRVB_STP_SAME_FIELD=600.0;   // m: start spots closer than this are one runway// A runway belongs to the nearest base within this

FsRvbMapInfo::FsRvbMapInfo()
{
	valid=YSFALSE;
	for(int i=0; i<FS_IFF_NEUTRAL; ++i)
	{
		teamValid[i]=YSFALSE;
		teamCenter[i]=YsOrigin();
	}
	frontCenter=YsOrigin();
	axis=YsXVec();
	lateral=YsZVec();
	axisExtent[0]=-20000.0;
	axisExtent[1]= 20000.0;
	lateralExtent[0]=-20000.0;
	lateralExtent[1]= 20000.0;
}

void FsRvbMapInfo::Build(FsSimulation *sim)
{
	base.Clear();
	runway.Clear();
	gnd.Clear();
	for(int i=0; i<FS_IFF_NEUTRAL; ++i)
	{
		teamValid[i]=YSFALSE;
	}

	BuildGround(sim);
	BuildTeams(sim);
	BuildBases(sim);
	BuildRunways(sim);
	BuildExtents();
	CountDefenders();
	valid=YSTRUE;
}

void FsRvbMapInfo::Refresh(FsSimulation *sim)
{
	for(auto &b : base)
	{
		if(FsSimInfo::CARRIER==b.type)
		{
			const FsGround *carrier=sim->FindGround(b.carrierKey);
			if(NULL!=carrier)
			{
				b.pos=carrier->GetPosition();
			}
		}
	}
}

void FsRvbMapInfo::BuildGround(FsSimulation *sim)
{
	for(FsGround *g=NULL; NULL!=(g=sim->FindNextGround(g)); )
	{
		if(YSTRUE!=g->IsAlive() || YSTRUE==g->Prop().IsNonGameObject())
		{
			continue;
		}

		double threat=0.0;
		if(0<g->Prop().GetNumSAM())
		{
			threat=YsGreater(threat,g->Prop().GetSAMRange());
		}
		if(0<g->Prop().GetNumAaaBullet())
		{
			threat=YsGreater(threat,g->Prop().GetAAARange());
		}

		gnd.Increment();
		gnd.Last().key=g->SearchKey();
		gnd.Last().iff=g->iff;
		gnd.Last().pos=g->GetPosition();
		gnd.Last().primary=g->primaryTarget;
		gnd.Last().threatRange=threat;
		gnd.Last().nDefender=0;
	}
}

void FsRvbMapInfo::CountDefenders(void)
{
	// Once per mission: ~500 objects -> ~250k distance tests, well under a millisecond.
	for(auto &g : gnd)
	{
		for(auto &d : gnd)
		{
			if(0.0<d.threatRange && d.iff==g.iff && (d.pos-g.pos).GetSquareLengthXZ()<d.threatRange*d.threatRange)
			{
				++g.nDefender;
			}
		}
	}
}

void FsRvbMapInfo::BuildTeams(FsSimulation *sim)
{
	int nAir[FS_IFF_NEUTRAL];
	YsVec3 airSum[FS_IFF_NEUTRAL];
	for(int i=0; i<FS_IFF_NEUTRAL; ++i)
	{
		nAir[i]=0;
		airSum[i]=YsOrigin();
	}
	for(FsAirplane *air=NULL; NULL!=(air=sim->FindNextAirplane(air)); )
	{
		if(0<=air->iff && air->iff<FS_IFF_NEUTRAL)
		{
			teamValid[air->iff]=YSTRUE;
			++nAir[air->iff];
			airSum[air->iff]+=air->GetPosition();
		}
	}

	// Team side = centre of its ground objects; aircraft positions if it owns none.
	int nGnd[FS_IFF_NEUTRAL];
	YsVec3 gndSum[FS_IFF_NEUTRAL];
	for(int i=0; i<FS_IFF_NEUTRAL; ++i)
	{
		nGnd[i]=0;
		gndSum[i]=YsOrigin();
	}
	for(auto &g : gnd)
	{
		if(0<=g.iff && g.iff<FS_IFF_NEUTRAL)
		{
			++nGnd[g.iff];
			gndSum[g.iff]+=g.pos;
		}
	}
	for(int i=0; i<FS_IFF_NEUTRAL; ++i)
	{
		if(YSTRUE==teamValid[i])
		{
			if(0<nGnd[i])
			{
				teamCenter[i]=gndSum[i]/(double)nGnd[i];
			}
			else if(0<nAir[i])
			{
				teamCenter[i]=airSum[i]/(double)nAir[i];
			}
			teamCenter[i].SetY(0.0);
		}
	}

	// Front line between the first two teams.
	int t[2]={-1,-1};
	for(int i=0; i<FS_IFF_NEUTRAL; ++i)
	{
		if(YSTRUE==teamValid[i])
		{
			if(0>t[0])
			{
				t[0]=i;
			}
			else if(0>t[1])
			{
				t[1]=i;
			}
		}
	}
	if(0<=t[0] && 0<=t[1])
	{
		frontCenter=(teamCenter[t[0]]+teamCenter[t[1]])/2.0;
		axis=teamCenter[t[1]]-teamCenter[t[0]];
		axis.SetY(0.0);
		if(YSOK!=axis.Normalize())
		{
			axis=YsXVec();
		}
	}
	else if(0<=t[0])
	{
		frontCenter=teamCenter[t[0]];
	}
	lateral.Set(-axis.z(),0.0,axis.x());
}

FSIFF FsRvbMapInfo::GuessOwner(const YsVec3 &pos,const double radius) const
{
	int count[FS_IFF_NEUTRAL];
	for(int i=0; i<FS_IFF_NEUTRAL; ++i)
	{
		count[i]=0;
	}
	for(auto &g : gnd)
	{
		if(0<=g.iff && g.iff<FS_IFF_NEUTRAL && YSTRUE==teamValid[g.iff] &&
		   (g.pos-pos).GetSquareLengthXZ()<radius*radius)
		{
			++count[g.iff];
		}
	}
	int best=-1;
	for(int i=0; i<FS_IFF_NEUTRAL; ++i)
	{
		if(YSTRUE==teamValid[i] && 0<count[i] && (0>best || count[best]<count[i]))
		{
			best=i;
		}
	}
	if(0>best)
	{
		// Nobody's objects around: the nearest team side owns it.
		double bestDist=YsInfinity;
		for(int i=0; i<FS_IFF_NEUTRAL; ++i)
		{
			const double d=(teamCenter[i]-pos).GetSquareLengthXZ();
			if(YSTRUE==teamValid[i] && d<bestDist)
			{
				best=i;
				bestDist=d;
			}
		}
	}
	return (0<=best ? (FSIFF)best : FS_IFF_NEUTRAL);
}

/* static */ YsArray <FsRvbMapInfo::StartRunway> &FsRvbMapInfo::StartRunways(void)
{
	static YsArray <StartRunway> lst;
	return lst;
}

/* static */ void FsRvbMapInfo::ClearStartRunways(void)
{
	StartRunways().Clear();
}

/* static */ void FsRvbMapInfo::AddStartRunway(const char name[],FSIFF iff,const YsVec3 &pos,const YsVec3 &dir)
{
	// Several start spots on one runway ("DIRT_STRIP", "DIRT_STIP_RUWNAY"): keep the first.
	for(auto &r : StartRunways())
	{
		if(r.iff==iff && (r.pos-pos).GetSquareLengthXZ()<FSRVB_STP_SAME_FIELD*FSRVB_STP_SAME_FIELD)
		{
			return;
		}
	}
	StartRunways().Increment();
	StartRunways().Last().name=name;
	StartRunways().Last().iff=iff;
	StartRunways().Last().pos=pos;
	StartRunways().Last().dir=dir;
}

YSBOOL FsRvbMapInfo::BuildStartRunwayAirfields(void)
{
	// Airfields from the map's runway start spots (the bridge reads the .stp).  Community maps like Luavi
	// have no airport regions, road segments as runway regions and land ILS not registered as ILS; the
	// start spots are the one reliable source.  Spot = runway start, its heading = runway direction.
	for(auto &r : StartRunways())
	{
		if(0>r.iff || FS_IFF_NEUTRAL<=r.iff || YSTRUE!=teamValid[r.iff])
		{
			continue;
		}
		YsVec3 dir=r.dir;
		dir.SetY(0.0);
		if(YSOK!=dir.Normalize())
		{
			continue;
		}
		runway.Increment();
		runway.Last().iff=r.iff;
		runway.Last().end[0]=r.pos;
		runway.Last().end[1]=r.pos+dir*FSRVB_STP_RUNWAY_LENGTH;
		runway.Last().width=45.0;

		base.Increment();
		base.Last().type=FsSimInfo::AIRPORT;
		base.Last().tag=r.name;
		base.Last().iff=r.iff;
		base.Last().carrierKey=YSNULLHASHKEY;
		base.Last().pos=r.pos+dir*(FSRVB_STP_RUNWAY_LENGTH/2.0);
	}
	return (0<runway.GetN() ? YSTRUE : YSFALSE);
}

void FsRvbMapInfo::BuildBases(FsSimulation *sim)
{
	const FsField *fld=sim->GetField();
	if(YSTRUE!=BuildStartRunwayAirfields() && NULL!=fld)
	{
		YsArray <const YsSceneryRectRegion *,16> rgnLst;
		fld->SearchFieldRegionById(rgnLst,FS_RGNID_AIRPORT_AREA);
		for(auto rgn : rgnLst)
		{
			YsVec3 rect[4];
			if(YSOK!=fld->GetFieldRegionRect(rect,rgn) || 0==strlen(rgn->GetTag()))
			{
				continue;
			}
			const YsVec3 cen=(rect[0]+rect[1]+rect[2]+rect[3])/4.0;
			const double radius=YsGreater((rect[0]-rect[2]).GetLength(),(rect[1]-rect[3]).GetLength())/2.0;

			base.Increment();
			base.Last().type=FsSimInfo::AIRPORT;
			base.Last().tag=rgn->GetTag();
			base.Last().iff=GuessOwner(cen,radius+FSRVB_OWNER_RADIUS);
			base.Last().carrierKey=YSNULLHASHKEY;
			base.Last().pos=cen;
		}
	}

	// Carriers with a tag (the map names the ones meant as bases).
	for(int i=0; i<sim->GetNumAircraftCarrier(); ++i)
	{
		const FsGround *carrier=sim->GetAircraftCarrier(i);
		if(NULL==carrier || YSTRUE!=carrier->IsAlive() || 0==strlen(carrier->GetName()) ||
		   0>carrier->iff || FS_IFF_NEUTRAL<=carrier->iff || YSTRUE!=teamValid[carrier->iff])
		{
			continue;
		}
		base.Increment();
		base.Last().type=FsSimInfo::CARRIER;
		base.Last().tag=carrier->GetName();
		base.Last().iff=carrier->iff;
		base.Last().carrierKey=carrier->SearchKey();
		base.Last().pos=carrier->GetPosition();
	}
}

void FsRvbMapInfo::BuildRunways(FsSimulation *sim)
{
	const FsField *fld=sim->GetField();
	if(NULL==fld || 0<runway.GetN())  // Runways already known from the start spots
	{
		return;
	}
	YsArray <const YsSceneryRectRegion *,16> rgnLst;
	fld->SearchFieldRegionById(rgnLst,FS_RGNID_RUNWAY);
	for(auto rgn : rgnLst)
	{
		YsVec3 rect[4];
		if(YSOK!=fld->GetFieldRegionRect(rect,rgn))
		{
			continue;
		}
		// Centre line along the long side.
		const double l01=(rect[1]-rect[0]).GetLength();
		const double l12=(rect[2]-rect[1]).GetLength();
		YsVec3 e0,e1;
		double width;
		if(l01>=l12)
		{
			e0=(rect[0]+rect[3])/2.0;
			e1=(rect[1]+rect[2])/2.0;
			width=l12;
		}
		else
		{
			e0=(rect[0]+rect[1])/2.0;
			e1=(rect[2]+rect[3])/2.0;
			width=l01;
		}
		if(YsGreater(l01,l12)<500.0)  // Taxiway stubs and pads are not worth a heavy bomber
		{
			continue;
		}

		const YsVec3 mid=(e0+e1)/2.0;
		FSIFF owner=FS_IFF_NEUTRAL;
		double bestDist=FSRVB_RUNWAY_BASE_DIST*FSRVB_RUNWAY_BASE_DIST;
		for(auto &b : base)
		{
			const double d=(b.pos-mid).GetSquareLengthXZ();
			if(FsSimInfo::AIRPORT==b.type && d<bestDist)
			{
				owner=b.iff;
				bestDist=d;
			}
		}
		if(FS_IFF_NEUTRAL==owner)
		{
			owner=GuessOwner(mid,FSRVB_OWNER_RADIUS);
		}

		runway.Increment();
		runway.Last().iff=owner;
		runway.Last().end[0]=e0;
		runway.Last().end[1]=e1;
		runway.Last().width=width;
	}
}

void FsRvbMapInfo::BuildExtents(void)
{
	YSBOOL first=YSTRUE;
	auto add=[&](const YsVec3 &p)
	{
		const YsVec3 rel=p-frontCenter;
		const double a=rel.x()*axis.x()+rel.z()*axis.z();
		const double l=rel.x()*lateral.x()+rel.z()*lateral.z();
		if(YSTRUE==first)
		{
			axisExtent[0]=axisExtent[1]=a;
			lateralExtent[0]=lateralExtent[1]=l;
			first=YSFALSE;
		}
		axisExtent[0]=YsSmaller(axisExtent[0],a);
		axisExtent[1]=YsGreater(axisExtent[1],a);
		lateralExtent[0]=YsSmaller(lateralExtent[0],l);
		lateralExtent[1]=YsGreater(lateralExtent[1],l);
	};
	for(auto &g : gnd)
	{
		add(g.pos);
	}
	for(auto &b : base)
	{
		add(b.pos);
	}
	if(YSTRUE==first)
	{
		return;  // Keep the defaults
	}
	axisExtent[0]-=FSRVB_AREA_MARGIN;
	axisExtent[1]+=FSRVB_AREA_MARGIN;
	lateralExtent[0]-=FSRVB_AREA_MARGIN;
	lateralExtent[1]+=FSRVB_AREA_MARGIN;
}

double FsRvbMapInfo::OwnSideness(FSIFF iff,const YsVec3 &pos) const
{
	const YsVec3 dir=OwnSideDir(iff);
	const YsVec3 rel=pos-frontCenter;
	const double along=rel.x()*dir.x()+rel.z()*dir.z();
	const double halfDepth=YsGreater(1.0,(axisExtent[1]-axisExtent[0])/2.0);
	return YsBound(along/halfDepth,-1.0,1.0);
}

YsVec3 FsRvbMapInfo::OwnSideDir(FSIFF iff) const
{
	if(0<=iff && iff<FS_IFF_NEUTRAL && YSTRUE==teamValid[iff])
	{
		YsVec3 dir=teamCenter[iff]-frontCenter;
		dir.SetY(0.0);
		if(YSOK==dir.Normalize())
		{
			return dir;
		}
	}
	return -axis;
}

YsVec3 FsRvbMapInfo::MakePosition(FSIFF iff,const double along,const double across,const double alt) const
{
	YsVec3 pos=frontCenter+OwnSideDir(iff)*along+lateral*across;
	pos.SetY(alt);
	return pos;
}

const FsRvbMapInfo::Base *FsRvbMapInfo::NearestBase(FSIFF iff,const YsVec3 &from) const
{
	const Base *best=NULL;
	double bestDist=YsInfinity;
	for(auto &b : base)
	{
		const double d=(b.pos-from).GetSquareLengthXZ();
		if(b.iff==iff && d<bestDist)
		{
			best=&b;
			bestDist=d;
		}
	}
	return best;
}
