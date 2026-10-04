#ifndef FSRVBARRIVAL_IS_INCLUDED
#define FSRVBARRIVAL_IS_INCLUDED
/* { */

// RvB: the arrival follower (YSFlight RvB Edition, 2026-10-01; planning/AI_rebuild_plan.md, ground operations).
// Flies one runway's arrival plan (fsrvbairfieldplan.h) the way the user flew his replays:
//   approach line from the 7 km gate (heights / speeds / gear / flaps / spoilers blended between his low and
//   high runs) -> flare onto the touchdown zone -> roll-out and taxi along his line to a rearm spot -> instant
//   rearm (a short stop) -> taxi out -> take-off roll -> climb-out on the runway heading -> done.
// Safety margins against the user's numbers (one constant per phase, top of fsrvbarrival.cpp): taxi corners
// slower with early braking, taxi straights at his speed, touchdown never before the pavement.
// Ground traffic (bookings, hold lines, car-following) is in fsrvbtraffic.h.
// The pilot's hands (fsrvbhands.h) are the only thing that moves the controls.

#include "fsautopilot.h"
#include "fsrvbairfieldplan.h"
#include "fsrvbhands.h"

class FsRvbArrival : public FsAutopilot
{
public:
	enum PHASE
	{
		PHASE_APPROACH,  // To the gate, then along the approach line
		PHASE_HOLDING,   // Runway booked by someone else: orbit at the gate
		PHASE_FLARE,
		PHASE_TAXI_IN,   // Roll-out and taxi to the rearm spot
		PHASE_REARM,
		PHASE_TAXI_OUT,  // To the take-off roll start (hold short of the runway on the way)
		PHASE_LINEUP,    // Slowly onto the centre line heading before full power
		PHASE_TAKEOFF,
		PHASE_CLIMB,
		PHASE_DONE,
		PHASE_FAILED
	};

	enum HOLD_STATE
	{
		HOLD_NONE,
		HOLD_JOINING,    // Navigating towards holding circle tangent
		HOLD_ORBITING,   // Established on the circle with radial-error correction
		HOLD_REJOINING   // Leaving hold to intercept the approach gate/line
	};

	// What happened, for the test harness (tools/ai_arrival_test.py)
	class Report
	{
	public:
		YSBOOL touchedDown;
		double tdAlong,tdCross,tdSpeed,tdSink,tdTime;
		double offPavementTime;
		YsVec3 offPavementPos;
		YSBOOL rearmed;
		YsString rearmSpot;
		double rearmStopError,rearmTime;  // m from the plan's stop spot
		YSBOOL airborne;
		double liftoffAlong,liftoffSpeed,airborneTime;
		double waitTime;                  // s held by traffic
		int goArounds;
		int gateChanges;                  // Times gate changed during hold (must be 0)
		double holdMaxDist;               // Max distance from runway threshold during hold
		double holdRadialErrMax;          // Max radial error observed during hold
		double holdEstablishedRadialErrMax; // Max radial error strictly in established orbit (HOLD_ORBITING)
		double holdOrbitDuration;         // Sustained seconds in HOLD_ORBITING
		double minTerrainClearance;       // Lowest AGL observed
		YsString failReason;
		Report();
	};

	static FsRvbArrival *Create(const FsRvbAirfieldPlan *plan);
	static const char *PhaseToStr(PHASE p);
	static const char *HoldStateToStr(HOLD_STATE s);

	virtual FSAUTOPILOTTYPE Type(void) const override {return FSAUTOPILOT_RVBARRIVAL;}
	virtual YSBOOL IsTakingOff(void) const override;
	virtual YSBOOL IsLanding(void) override;
	virtual YSRESULT MakePriorityDecision(FsAirplane &air) override;
	virtual YSRESULT MakeDecision(FsAirplane &air,FsSimulation *sim,const double &dt) override;
	virtual YSRESULT ApplyControl(FsAirplane &air,FsSimulation *sim,const double &dt) override;
	virtual YSRESULT SaveIntention(FILE *fp,const FsSimulation *sim) override;

	PHASE GetPhase(void) const;
	HOLD_STATE GetHoldState(void) const;
	double GetPhaseTime(void) const;
	const Report &GetReport(void) const;
	const FsRvbAirfieldPlan *GetPlan(void) const;
	const char *GetLineName(void) const;
	YSBOOL IsHeldByTraffic(void) const;
	const YsVec3 &GetHoldCenter(void) const;
	double GetHoldRadius(void) const;
	double GetHoldRadialError(void) const;
	double GetMinTerrainClearance(void) const;
	int GetGateChanges(void) const;
	double GetAssignedAlt(void) const;
	int GetHoldStackLevel(void) const;
	double GetHoldSpeed(void) const;
	double GetHoldOrbitDuration(void) const;
	double GetEstablishedRadialErrMax(void) const;
	YSBOOL HasClearance(const char zone[]) const;
	// Ground route being followed (NULL in the air) and the progress along it, for car-following
	const FsRvbPath *GetRoute(void) const;
	double GetRouteProgress(void) const;

protected:
	FsRvbArrival();
	virtual ~FsRvbArrival();

private:
	const FsRvbAirfieldPlan *plan;
	PHASE phase;
	double phaseTimer,clock;
	YSBOOL initialized;
	FsRvbHands hands;
	Report report;

	// Approach
	int lineIdx;
	double blend;          // 0 = the user's low run, 1 = his high run
	double sPath;
	YSBOOL gearLatched,flapLatched;
	FsRvbHands::AirIntent intent;
	double flareBank,flareVSpeed;

	// Ground
	int spotIdx;
	const FsRvbPath *route;
	YsArray <double> routeSpeed;  // The AI's planned speed per route point (the user's, with the margins)
	double sRoute;
	double holdLineS;            // Route position of the hold line: rearm zone (way in) or runway (way out)
	YsVec3 aim;
	double taxiSpeed;
	YSBOOL holding;              // Held by traffic this tick
	double stillTimer;
	double liftoffClock;
	YsVec3 liftoffPos;

	// Holding (YSFlight RvB Edition, 2026-10-03)
	YSHASHKEY airKey;
	HOLD_STATE holdState;
	int holdLineIdx;
	int initialHoldLineIdx;
	YsVec3 holdCenter;
	double holdRadius;
	double holdBaseAlt;          // Terrain-safe base altitude MSL
	double targetAlt;            // Assigned altitude MSL = holdBaseAlt + level * FSRVB_HOLD_STACK_SEP
	double holdSpeed;            // Achievable coordinated holding speed
	int holdStackLevel;
	double holdOrbitDuration;    // Sustained seconds in HOLD_ORBITING
	double holdRadialErrMax;
	double holdEstablishedRadialErrMax;
	double holdDistMax;
	double minTerrainClearance;
	double currentRadialError;
	int gateChanges;

	void Start(FsAirplane &air,FsSimulation *sim);
	void SetPhase(PHASE p);
	void Fail(const char reason[]);
	void ChooseLine(const FsAirplane &air);
	void BeginRoute(const FsRvbPath &path,FsAirplane &air,const YSBOOL wayOut);
	YsString RearmZone(const int spot) const;
	void PlanRouteSpeed(FsAirplane &air);
	double RunwayElevation(FsSimulation *sim) const;

	void EnterHolding(FsAirplane &air,FsSimulation *sim);
	void DecideApproach(FsAirplane &air,FsSimulation *sim,const double dt);
	void DecideHolding(FsAirplane &air,FsSimulation *sim,const double dt);
	void SelectHoldingParameters(const FsAirplane &air,double &outRadius,double &outSpeed) const;
	void DecideFlare(FsAirplane &air,FsSimulation *sim);
	void DecideTaxi(FsAirplane &air,FsSimulation *sim,const double dt);
	void DecideRearm(FsAirplane &air,FsSimulation *sim);
	void DecideLineUp(FsAirplane &air);
	void DecideTakeOff(FsAirplane &air,FsSimulation *sim);
	void DecideClimb(FsAirplane &air,FsSimulation *sim);
};

/* } */
#endif
