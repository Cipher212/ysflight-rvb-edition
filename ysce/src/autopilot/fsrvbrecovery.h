#ifndef FSRVBRECOVERY_IS_INCLUDED
#define FSRVBRECOVERY_IS_INCLUDED
/* { */

// RvB: RTB and turnaround for the RvB AI, flown like an RvB human pilot (YSFlight RvB Edition, 2026-09-30).
//   TRANSIT   run home at full military power, 1,000-1,500 m
//   PATTERN   military visual pattern (fsrvbapproach.h): downwind, one curved turn onto a 2.5 km final
//   APPROACH  YS landing autopilot from the final gate (straight-in); carriers: the YS ILS approach
//   ROLLOUT   brake to taxi speed
//   TAXI      straight to the nearest friendly fuel/supply object at up to 25 m/s (runway) / 12 m/s
//   REFUEL    stop next to it: fuel and weapons back in 5 s (no supply object near: in place after 8 s)
//   TAXI      to the nearer end of the runway, line up
//   TAKEOFF   YS take-off autopilot along the runway.  Carriers: on the catapult -> launch; a deck YS can
//             auto-taxi on -> YS carrier taxi to the catapult first; else a full-power deck run straight ahead.
// RTB goes to airfields (a carrier only when the team has none: carrier recoveries are not reliable yet).
// It uses the runways found by FsRvbMapInfo, so maps need no taxi paths or approach definitions.
// Also used for AIs that start (or respawn) on the ground: they begin at the taxi-to-runway step.

#include <ysclass.h>
#include <fsdef.h>
#include "fssiminfo.h"
#include "fsrvbapproach.h"
#include "fsrvbsurvival.h"

class FsAirplane;
class FsSimulation;
class FsRvbTeamPicture;
class FsGotoPosition;
class FsLandingAutopilot;
class FsTakeOffAutopilot;
class FsTaxiingAutopilot;

class FsRvbRecovery
{
public:
	enum STAGE
	{
		STAGE_IDLE,
		STAGE_TRANSIT,
		STAGE_PATTERN,      // RvB military pattern (FsRvbApproach) down to the final gate
		STAGE_APPROACH,     // YS landing autopilot: final, flare, touchdown (carriers: the whole ILS approach)
		STAGE_ROLLOUT,
		STAGE_TAXI_TO_SUPPLY,
		STAGE_REFUEL,
		STAGE_TAXI_TO_RUNWAY,
		STAGE_LINEUP,
		STAGE_CARRIER_TAXI,
		STAGE_TAKEOFF,
		STAGE_DONE          // Airborne after the take-off: the tactical AI takes over
	};

	FsRvbRecovery();
	~FsRvbRecovery();

	static const char *StageToStr(STAGE stage);

	void StartRtb(FsAirplane &air,FsSimulation *sim,const FsRvbTeamPicture &pic);
	void StartOnGround(FsAirplane &air,FsSimulation *sim,const FsRvbTeamPicture &pic);
	void Stop(void);

	STAGE GetStage(void) const;
	double GetStageTime(void) const;
	int GetLandingPhase(void) const;    // FsLandingAutopilot::landingPhase, -1 when not landing
	YSBOOL IsBusy(void) const;          // Between Start and STAGE_DONE
	YSBOOL IsInTheAirPhase(void) const; // TRANSIT: normal emergency recovery and defence still apply
	// PATTERN: the controls are this steering order (the tactical autopilot applies it).
	YSBOOL IsSteering(void) const;
	const FsRvbSteer &GetSteer(void) const;
	int nGoAround;                      // Patterns flown again (straight-in refused or timed out)

	YSRESULT MakeDecision(FsAirplane &air,FsSimulation *sim,const FsRvbTeamPicture &pic,const double dt);
	YSRESULT ApplyControl(FsAirplane &air,FsSimulation *sim,const double dt);

	int nRefuel;                        // Turnarounds completed by this aircraft
	static int nTotalLanding;           // All aircraft, since the program started (tests, log)
	static int nTotalRefuel;
	static int nTotalTakeoff;

private:
	STAGE stage;
	double stageTimer;
	double hdgErr;                      // Taxi steering error, for the speed choice

	FsSimInfo::BASE_TYPE baseType;
	YsString baseTag;
	YSHASHKEY carrierKey;
	YsVec3 basePos;

	YsVec3 rwyEnd[2];                   // Runway used at this base
	YSBOOL rwyValid;
	YsVec3 path[2];                     // Taxi waypoints
	int pathIdx,nPath;
	double taxiSpeed[2];                // Per waypoint
	double nearWaypointTime;
	double holdTimer;
	YSHASHKEY supplyKey;
	YSBOOL canRefuel;

	FsRvbApproach pattern;
	FsRvbSteer steer;
	YsVec3 landThreshold,landDir;

	FsGotoPosition *transitAP;
	FsLandingAutopilot *landingAP;
	FsTakeOffAutopilot *takeoffAP;
	FsTaxiingAutopilot *carrierTaxiAP;

	void SetStage(STAGE s);
	void ChooseBase(FsAirplane &air,const FsRvbTeamPicture &pic);
	void ChooseRunway(const FsAirplane &air,const FsRvbTeamPicture &pic);
	void BeginApproach(FsAirplane &air,FsSimulation *sim);
	void BeginFinal(FsAirplane &air,FsSimulation *sim);
	void BeginTaxiToSupply(FsAirplane &air,FsSimulation *sim);
	void BeginTaxiToRunway(FsAirplane &air);
	void BeginCarrierLaunch(FsAirplane &air);
	void BeginDeckLaunch(FsAirplane &air);
	void BeginTakeOff(FsAirplane &air,FsSimulation *sim,const YsVec3 &o,const YsVec3 &v);
	YSBOOL CirclingWaypoint(const FsAirplane &air,const double dt);
	YSBOOL SomethingAhead(const FsAirplane &air,const FsRvbTeamPicture &pic) const;
	YSBOOL RunwayBusy(const FsAirplane &air,const FsRvbTeamPicture &pic) const;
	YSBOOL HoldShort(const FsAirplane &air,const FsRvbTeamPicture &pic) const;
	void Taxi(FsAirplane &air,const YsVec3 &to,const double speed,const double dt);
	void Hold(FsAirplane &air);
	void ClearSubAutopilot(void);
};

/* } */
#endif
