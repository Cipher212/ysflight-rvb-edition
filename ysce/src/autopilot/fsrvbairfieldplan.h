#ifndef FSRVBAIRFIELDPLAN_IS_INCLUDED
#define FSRVBAIRFIELDPLAN_IS_INCLUDED
/* { */

// RvB: one runway's arrival plan, measured from the user's replays (YSFlight RvB Edition, 2026-10-01).
// Built by tools/maps/build_arrival_plan.py into godot_project/ai/<RUNWAY>.txt; the bridge feeds the lines in at
// load.  Holds the approach lines (gate -> touchdown, heights / speeds / gear / flaps / spoilers for a low and a
// high entry), the touchdown zone, the taxi route in to and out of every rearm spot, and the take-off.
// The plan keeps the user's own numbers; the AI's safety margins live in the follower (fsrvbarrival.cpp).

#include <ysclass.h>

// A polyline on the ground (x/z; y ignored) with a value per point, walked by arc length.
class FsRvbPath
{
public:
	YsArray <YsVec2> p;
	YsArray <double> s;   // Arc length at each point
	YsArray <double> v;   // The value per point (the user's speed on taxi routes)

	void Clear(void);
	void Add(const double x,const double z,const double value);
	double Length(void) const;
	int GetN(void) const;
	// Nearest arc length to pos, searched only within [sFrom,sTo] so loops and stubs keep their order.
	double Project(const YsVec3 &pos,const double sFrom,const double sTo) const;
	YsVec2 PointAt(const double sAt) const;  // Past the end: continues straight along the last segment
	YsVec2 DirAt(const double sAt) const;
	double ValueAt(const double sAt) const;
	int IndexAt(const double sAt) const;     // The segment that contains sAt
	// Turn per metre (1/radius) around sAt, measured over +-span metres
	double CurvatureAt(const double sAt,const double span) const;
};

class FsRvbApproachLine
{
public:
	enum
	{
		CFG_GEAR=1,
		CFG_FLAP=2,
		CFG_SPOILER=4
	};
	YsString name;           // FINAL / LEFT / RIGHT / BEYOND
	FsRvbPath path;          // Gate (first point) -> touchdown (last point)
	YsArray <double> y[2];   // [0] low entry, [1] high entry: height (m above sea level)
	YsArray <double> spd[2]; // m/s
	YsArray <unsigned> cfg[2];

	// blend 0 = the user's low run, 1 = the high run
	double HeightAt(const double sAt,const double blend) const;
	double SpeedAt(const double sAt,const double blend) const;
	unsigned ConfigAt(const double sAt,const double blend) const;
};

class FsRvbRearmSpot
{
public:
	YsString name;
	YsVec3 stopPos,supplyPos;
	double stopHeading;      // Compass degrees
	FsRvbPath in,out;        // in: touchdown -> stop, out: stop -> take-off roll start
};

class FsRvbClimbPoint
{
public:
	double dist,height,speed;  // m past lift-off, m above the runway, m/s
	YSBOOL gear,flap;
};

class FsRvbAirfieldPlan
{
public:
	YsString tag;            // e.g. COLE_29
	YsVec3 threshold;        // Pavement start on the centre line (y = 0: use the field elevation)
	YsVec3 landDir;          // Unit, horizontal
	double length,width;
	double tdMedian,tdMin,tdMax,tdSpeed;  // The user's touchdowns: m past the threshold, m/s
	YsArray <FsRvbApproachLine> approach;
	YsArray <FsRvbRearmSpot> rearm;
	YsVec3 rollStart;
	double rotateSpeed,liftoffSpeed,liftoffPitch;  // m/s, m/s, rad
	YsArray <FsRvbClimbPoint> climb;

	FsRvbAirfieldPlan();
	double Along(const YsVec3 &pos) const;  // m past the threshold
	double Cross(const YsVec3 &pos) const;  // m right of the centre line
	YsVec3 OnCentreLine(const double along) const;

	// Registry: the bridge clears it, then feeds each plan file line by line.
	static void ClearAll(void);
	static FsRvbAirfieldPlan *Begin(const char tag[]);
	YSRESULT AddLine(const char line[]);  // Returns YSERR for a line it does not understand
	static const FsRvbAirfieldPlan *Find(const char tag[]);
	static int GetNumPlan(void);
	static const FsRvbAirfieldPlan *GetPlan(int i);

private:
	enum READING
	{
		READING_NONE,
		READING_APPROACH,  // A lines go to approach.Last()
		READING_ROUTE_IN,  // R lines go to rearm.Last().in
		READING_ROUTE_OUT
	};
	READING reading;
};

/* } */
#endif
