#ifndef FSRVBAPPROACH_IS_INCLUDED
#define FSRVBAPPROACH_IS_INCLUDED
/* { */

// RvB: military visual approach for the RvB AI (YSFlight RvB Edition, 2026-09-30).  Kai Tak style: no long
// straight-in, no airliner pattern.
//   ENTRY     to abeam the far half of the runway, 2R out on the aircraft's side, 400 m above the field
//   DOWNWIND  opposite to the landing direction, slowing to 1.3 x the landing speed, gear down, 350 m
//   TURN      one continuous descending turn of radius R onto a 2.5 km final
//   GATE      aligned on a short final below the glide path: YS's landing autopilot takes it from here
//             (straight-in, flare, touchdown).  R comes from the pattern speed at ~50 deg of bank.
// If the pattern takes too long it reports FAILED and the recovery flies it again.

#include <ysclass.h>

class FsAirplane;
class FsRvbSteer;

class FsRvbApproach
{
public:
	enum PHASE
	{
		PHASE_IDLE,
		PHASE_ENTRY,
		PHASE_DOWNWIND,
		PHASE_TURN,
		PHASE_GATE,
		PHASE_FAILED
	};

	FsRvbApproach();
	void Start(const FsAirplane &air,const YsVec3 &threshold,const YsVec3 &landDir,const double runwayLength);
	PHASE GetPhase(void) const;
	void Update(FsRvbSteer &steer,const FsAirplane &air,const double dt);

	static const double finalLength;

private:
	PHASE phase;
	double phaseTimer,totalTimer;
	YsVec3 thr,dir,side;
	double lng,radius,patternSpeed;

	double Along(const YsVec3 &p) const;
	double Lateral(const YsVec3 &p) const;
	void SetPhase(PHASE p);
};

/* } */
#endif
