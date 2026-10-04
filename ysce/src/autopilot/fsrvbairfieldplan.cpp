#include <ysclass.h>

#include "fsrvbairfieldplan.h"

// RvB: see fsrvbairfieldplan.h (YSFlight RvB Edition, 2026-10-01).

static YsArray <FsRvbAirfieldPlan *> &FsRvbPlanList(void)
{
	static YsArray <FsRvbAirfieldPlan *> lst;
	return lst;
}

static YsVec2 FsRvbCompassToDir(const double deg)
{
	return YsVec2(sin(YsDegToRad(deg)),cos(YsDegToRad(deg)));
}

////////////////////////////////////////////////////////////

void FsRvbPath::Clear(void)
{
	p.Clear();
	s.Clear();
	v.Clear();
}

void FsRvbPath::Add(const double x,const double z,const double value)
{
	const YsVec2 q(x,z);
	s.Append(0<p.GetN() ? s.Last()+(q-p.Last()).GetLength() : 0.0);
	p.Append(q);
	v.Append(value);
}

double FsRvbPath::Length(void) const
{
	return (0<s.GetN() ? s.Last() : 0.0);
}

int FsRvbPath::GetN(void) const
{
	return (int)p.GetN();
}

int FsRvbPath::IndexAt(const double sAt) const
{
	// Binary search: the segment [i,i+1] that contains sAt
	int lo=0,hi=(int)s.GetN()-1;
	if(hi<1 || sAt<=s[0])
	{
		return 0;
	}
	if(sAt>=s[hi])
	{
		return hi-1;
	}
	while(1<hi-lo)
	{
		const int mid=(lo+hi)/2;
		if(s[mid]<=sAt)
		{
			lo=mid;
		}
		else
		{
			hi=mid;
		}
	}
	return lo;
}

YsVec2 FsRvbPath::PointAt(const double sAt) const
{
	if(p.GetN()<2)
	{
		return (0<p.GetN() ? p[0] : YsVec2(0.0,0.0));
	}
	const int i=IndexAt(sAt);
	const double segLen=s[i+1]-s[i];
	const double t=(YsTolerance<segLen ? (sAt-s[i])/segLen : 0.0);  // <0 or >1 extrapolates at the ends
	return p[i]+(p[i+1]-p[i])*t;
}

YsVec2 FsRvbPath::DirAt(const double sAt) const
{
	if(p.GetN()<2)
	{
		return YsVec2(0.0,1.0);
	}
	const int i=IndexAt(sAt);
	YsVec2 d=p[i+1]-p[i];
	d.Normalize();
	return d;
}

double FsRvbPath::ValueAt(const double sAt) const
{
	if(v.GetN()<2)
	{
		return (0<v.GetN() ? v[0] : 0.0);
	}
	const int i=IndexAt(sAt);
	const double segLen=s[i+1]-s[i];
	const double t=YsBound(YsTolerance<segLen ? (sAt-s[i])/segLen : 0.0,0.0,1.0);
	return v[i]*(1.0-t)+v[i+1]*t;
}

double FsRvbPath::Project(const YsVec3 &pos,const double sFrom,const double sTo) const
{
	if(p.GetN()<2)
	{
		return 0.0;
	}
	const YsVec2 q(pos.x(),pos.z());
	const int i0=IndexAt(sFrom),i1=IndexAt(sTo);
	double bestS=YsBound(sFrom,0.0,Length()),bestD2=YsInfinity;
	for(int i=i0; i<=i1; ++i)
	{
		const YsVec2 d=p[i+1]-p[i];
		const double l2=d.GetSquareLength();
		const double t=(YsTolerance<l2 ? YsBound(((q-p[i])*d)/l2,0.0,1.0) : 0.0);
		const double d2=(p[i]+d*t-q).GetSquareLength();
		if(d2<bestD2)
		{
			bestD2=d2;
			bestS=s[i]+(s[i+1]-s[i])*t;
		}
	}
	return bestS;
}

double FsRvbPath::CurvatureAt(const double sAt,const double span) const
{
	const YsVec2 a=DirAt(sAt-span),b=DirAt(sAt+span);
	const double turn=atan2(a.x()*b.y()-a.y()*b.x(),a*b);
	return fabs(turn)/(2.0*span);
}

////////////////////////////////////////////////////////////

double FsRvbApproachLine::HeightAt(const double sAt,const double blend) const
{
	const int i=path.IndexAt(sAt);
	if(path.GetN()<2)
	{
		return 0.0;
	}
	const double t=YsBound((sAt-path.s[i])/YsGreater(YsTolerance,path.s[i+1]-path.s[i]),0.0,1.0);
	const double lo=y[0][i]*(1.0-t)+y[0][i+1]*t;
	const double hi=y[1][i]*(1.0-t)+y[1][i+1]*t;
	return lo*(1.0-blend)+hi*blend;
}

double FsRvbApproachLine::SpeedAt(const double sAt,const double blend) const
{
	const int i=path.IndexAt(sAt);
	if(path.GetN()<2)
	{
		return 0.0;
	}
	const double t=YsBound((sAt-path.s[i])/YsGreater(YsTolerance,path.s[i+1]-path.s[i]),0.0,1.0);
	const double lo=spd[0][i]*(1.0-t)+spd[0][i+1]*t;
	const double hi=spd[1][i]*(1.0-t)+spd[1][i+1]*t;
	return lo*(1.0-blend)+hi*blend;
}

unsigned FsRvbApproachLine::ConfigAt(const double sAt,const double blend) const
{
	// A device is out when the blend of the two runs says at least half out.
	const int i=YsBound(path.IndexAt(sAt)+1,0,path.GetN()-1);
	unsigned out=0;
	for(unsigned bit : {(unsigned)CFG_GEAR,(unsigned)CFG_FLAP,(unsigned)CFG_SPOILER})
	{
		const double lo=(0!=(cfg[0][i]&bit) ? 1.0 : 0.0);
		const double hi=(0!=(cfg[1][i]&bit) ? 1.0 : 0.0);
		if(0.5<=lo*(1.0-blend)+hi*blend)
		{
			out|=bit;
		}
	}
	return out;
}

////////////////////////////////////////////////////////////

FsRvbAirfieldPlan::FsRvbAirfieldPlan()
{
	threshold=YsOrigin();
	landDir=YsZVec();
	length=0.0;
	width=0.0;
	tdMedian=tdMin=tdMax=0.0;
	tdSpeed=0.0;
	rollStart=YsOrigin();
	rotateSpeed=liftoffSpeed=0.0;
	liftoffPitch=0.0;
	reading=READING_NONE;
}

double FsRvbAirfieldPlan::Along(const YsVec3 &pos) const
{
	return (pos.x()-threshold.x())*landDir.x()+(pos.z()-threshold.z())*landDir.z();
}

double FsRvbAirfieldPlan::Cross(const YsVec3 &pos) const
{
	return (pos.x()-threshold.x())*landDir.z()-(pos.z()-threshold.z())*landDir.x();
}

YsVec3 FsRvbAirfieldPlan::OnCentreLine(const double along) const
{
	return threshold+landDir*along;
}

/* static */ void FsRvbAirfieldPlan::ClearAll(void)
{
	for(auto ptr : FsRvbPlanList())
	{
		delete ptr;
	}
	FsRvbPlanList().Clear();
}

/* static */ FsRvbAirfieldPlan *FsRvbAirfieldPlan::Begin(const char tag[])
{
	FsRvbAirfieldPlan *plan=new FsRvbAirfieldPlan;
	plan->tag.Set(tag);
	plan->tag.Capitalize();
	FsRvbPlanList().Append(plan);
	return plan;
}

/* static */ const FsRvbAirfieldPlan *FsRvbAirfieldPlan::Find(const char tag[])
{
	for(auto ptr : FsRvbPlanList())
	{
		if(0==ptr->tag.STRCMP(tag))
		{
			return ptr;
		}
	}
	return NULL;
}

/* static */ int FsRvbAirfieldPlan::GetNumPlan(void)
{
	return (int)FsRvbPlanList().GetN();
}

/* static */ const FsRvbAirfieldPlan *FsRvbAirfieldPlan::GetPlan(int i)
{
	return (FsRvbPlanList().IsInRange(i) ? FsRvbPlanList()[i] : NULL);
}

YSRESULT FsRvbAirfieldPlan::AddLine(const char line[])
{
	YsString str(line);
	for(YSSIZE_T i=0; i<str.Strlen(); ++i)
	{
		if('#'==str[i])
		{
			str.SetLength(i);
			break;
		}
	}
	YsArray <YsString,16> args;
	if(YSOK!=str.Arguments(args) || 0==args.GetN())
	{
		return YSOK;  // Blank or comment
	}
	auto num=[&args](int i) -> double {return (i<args.GetN() ? atof(args[i]) : 0.0);};
	const YsString &key=args[0];

	if(0==strcmp(key,"A") && READING_APPROACH==reading && 12<=args.GetN())
	{
		FsRvbApproachLine &a=approach.Last();
		a.path.Add(num(1),num(2),0.0);
		for(int lv=0; lv<2; ++lv)
		{
			const int o=3+lv*5;
			a.y[lv].Append(num(o));
			a.spd[lv].Append(num(o+1));
			a.cfg[lv].Append((0!=atoi(args[o+2]) ? FsRvbApproachLine::CFG_GEAR : 0)|
			                 (0!=atoi(args[o+3]) ? FsRvbApproachLine::CFG_FLAP : 0)|
			                 (0!=atoi(args[o+4]) ? FsRvbApproachLine::CFG_SPOILER : 0));
		}
		return YSOK;
	}
	if(0==strcmp(key,"R") && (READING_ROUTE_IN==reading || READING_ROUTE_OUT==reading) && 4<=args.GetN())
	{
		FsRvbPath &path=(READING_ROUTE_IN==reading ? rearm.Last().in : rearm.Last().out);
		path.Add(num(1),num(2),num(3));
		return YSOK;
	}

	reading=READING_NONE;
	if(0==strcmp(key,"RUNWAY") && 6<=args.GetN())
	{
		const YsVec2 d=FsRvbCompassToDir(num(3));
		threshold.Set(num(1),0.0,num(2));
		landDir.Set(d.x(),0.0,d.y());
		length=num(4);
		width=num(5);
	}
	else if(0==strcmp(key,"TOUCHDOWN") && 4<=args.GetN())
	{
		tdMedian=num(1);
		tdMin=num(2);
		tdMax=num(3);
	}
	else if(0==strcmp(key,"TOUCHDOWN_SPEED") && 2<=args.GetN())
	{
		tdSpeed=num(1);
	}
	else if(0==strcmp(key,"APPROACH") && 2<=args.GetN())
	{
		approach.Increment();
		approach.Last().name=args[1];
		reading=READING_APPROACH;
	}
	else if(0==strcmp(key,"REARM") && 7<=args.GetN())
	{
		rearm.Increment();
		FsRvbRearmSpot &r=rearm.Last();
		r.name=args[1];
		r.stopPos.Set(num(2),0.0,num(3));
		r.stopHeading=num(4);
		r.supplyPos.Set(num(5),0.0,num(6));
	}
	else if(0==strcmp(key,"ROUTE") && 3<=args.GetN() && 0<rearm.GetN() && 0==rearm.Last().name.STRCMP(args[1]))
	{
		reading=(0==strcmp(args[2],"IN") ? READING_ROUTE_IN : READING_ROUTE_OUT);
	}
	else if(0==strcmp(key,"TAKEOFF") && 6<=args.GetN())
	{
		rollStart.Set(num(1),0.0,num(2));
		rotateSpeed=num(3);
		liftoffSpeed=num(4);
		liftoffPitch=YsDegToRad(num(5));
	}
	else if(0==strcmp(key,"CLIMB") && 6<=args.GetN())
	{
		FsRvbClimbPoint c;
		c.dist=num(1);
		c.height=num(2);
		c.speed=num(3);
		c.gear=(0!=atoi(args[4]) ? YSTRUE : YSFALSE);
		c.flap=(0!=atoi(args[5]) ? YSTRUE : YSFALSE);
		climb.Append(c);
	}
	else
	{
		return YSERR;
	}
	return YSOK;
}
