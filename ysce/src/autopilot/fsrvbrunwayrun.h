#ifndef FSRVBRUNWAYRUN_IS_INCLUDED
#define FSRVBRUNWAYRUN_IS_INCLUDED
/* { */

// RvB: the HEAVY role's runway attack (YSFlight RvB Edition, 2026-09-30).
//   CLIMB    to the attack altitude (8,000 m+) over the own side
//   INGRESS  to an initial point on the runway's extended centre line, far enough out to settle
//   RUN      straight and level along the runway, bombs released so they walk down its length
//            (impact points spread evenly, 10%-90% of the runway; release = predicted impact point)
//   EGRESS   gentle turn back to the own side (bank for < 5 G), then done
// It never manoeuvres hard: the role has no dogfighting skills.

#include <ysclass.h>
#include <fsdef.h>

class FsAirplane;
class FsSimulation;
class FsRvbSteer;
class FsRvbDoctrine;

class FsRvbRunwayRun
{
public:
	enum PHASE
	{
		PHASE_IDLE,
		PHASE_CLIMB,
		PHASE_INGRESS,
		PHASE_RUN,
		PHASE_EGRESS,
		PHASE_DONE
	};

	FsRvbRunwayRun();
	// run[0] -> run[1] is the bombing direction; climbPos is where to reach altitude; homeDir points home.
	void Start(const YsVec3 &runStart,const YsVec3 &runEnd,const YsVec3 &climbPos,const YsVec3 &homeDir);
	PHASE GetPhase(void) const;
	int GetNumReleased(void) const;

	void Update(FsRvbSteer &steer,FsAirplane &air,FsSimulation *sim,const FsRvbDoctrine &doc,const double dt);

private:
	PHASE phase;
	YsVec3 run[2],climbPos,homeDir;
	int nAim,nextAim,nReleased;
	double phaseTimer;

	static int CountBombs(const FsAirplane &air);
	static FSWEAPONTYPE NextBombType(const FsAirplane &air);
	YsVec3 AimPoint(int i) const;
};

/* } */
#endif
