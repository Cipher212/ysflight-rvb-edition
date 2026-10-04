#ifndef FSRVBTRAFFIC_IS_INCLUDED
#define FSRVBTRAFFIC_IS_INCLUDED
/* { */

// RvB: ground traffic rules for the arrival follower (YSFlight RvB Edition, 2026-10-01; agreed with the user,
// planning/AI_rebuild_plan.md "Traffic on the ground").
// (1) Bookings: the runway and each rearm spot (with its stub) are one-jet zones.  Book before entering, else
//     wait at the hold line before it.  (2) Car-following on every route: keep a gap to anything ahead on the
//     route - AI or human - slowing as it shrinks.  (3) Priority: landing traffic first; a departure does not take
//     the runway while an arrival is close in.

#include <ysclass.h>

class FsAirplane;
class FsSimulation;
class FsRvbPath;
class FsRvbAirfieldPlan;

class FsRvbTraffic
{
public:
	static void Reset(void);
	// YSTRUE when who holds the zone (already, or booked now because it was free)
	static YSBOOL Book(const FsRvbAirfieldPlan *plan,const char zone[],YSHASHKEY who);
	static void Release(const FsRvbAirfieldPlan *plan,const char zone[],YSHASHKEY who);
	static void ReleaseAll(YSHASHKEY who);
	static YSBOOL IsFree(const FsRvbAirfieldPlan *plan,const char zone[],YSHASHKEY askedBy);
	static int Uses(const FsRvbAirfieldPlan *plan,const char zone[]);  // Bookings so far (to spread jets out)

	// Speed limit (m/s) behind the nearest aircraft on my route ahead: stop gap, then sqrt(2 a d).
	static double FollowLimit(const FsAirplane &me,FsSimulation *sim,const FsRvbPath &route,const double sMe,
	                          const double decel);
	// An arrival on this runway closer than dist (m) to its touchdown, other than me?
	static YSBOOL ArrivalWithin(FsSimulation *sim,const FsRvbAirfieldPlan *plan,const double dist,const FsAirplane &me);

	// Airborne holding stack: FIFO queue of aircraft holding for this airfield (YSFlight RvB Edition, 2026-10-03)
	static int JoinHold(const FsRvbAirfieldPlan *plan,YSHASHKEY who);
	static void LeaveHold(const FsRvbAirfieldPlan *plan,YSHASHKEY who);
	static int GetHoldStackLevel(const FsRvbAirfieldPlan *plan,YSHASHKEY who);
	static int NumHolding(const FsRvbAirfieldPlan *plan);

	// Clearance query and death/removal cleanup (YSFlight RvB Edition, 2026-10-03)
	static YSBOOL HasClearance(const FsRvbAirfieldPlan *plan,const char zone[],YSHASHKEY who);
	static void PurgeDead(FsSimulation *sim);
};

/* } */
#endif
