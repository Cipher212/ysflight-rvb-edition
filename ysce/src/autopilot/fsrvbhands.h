#ifndef FSRVBHANDS_IS_INCLUDED
#define FSRVBHANDS_IS_INCLUDED
/* { */

// RvB: the pilot's hands (YSFlight RvB Edition, 2026-10-01; planning/AI_rebuild_plan.md principle 2).
// The only code of the new AI that touches an aircraft's controls.  The deciding layers say what they want -
// a bank, a vertical speed, a speed, a point to steer at on the ground - and the hands turn it into smooth,
// rate-limited stick, rudder, throttle, spoiler and brake through YS's own bank / G / pitch controllers.
// No sudden jumps: every output moves at a limited rate, so a changed mind never jerks the jet.

#include "fsdef.h"

class FsAirplane;
class FsSimulation;

class FsRvbHands
{
public:
	// What the deciding layer wants in the air
	class AirIntent
	{
	public:
		double bank;       // rad, + = left in YS (YSFlight RvB Edition, 2026-10-03)
		double vSpeed;     // m/s, + = climb
		double speed;      // m/s airspeed
		double gMax,gMin;
		YSBOOL afterburner;
		YSBOOL spoilerForSpeed;  // Spoilers out while well above the speed (the user's way to bleed speed)
		YSBOOL spoiler;          // Spoilers out regardless
		double gear,flap;        // 0..1
		YSBOOL idle;             // Throttle to idle (flare)
		AirIntent();
	};

	FsRvbHands();
	void Reset(const FsAirplane &air);

	void Fly(FsAirplane &air,const AirIntent &intent,const double dt);
	// The flare: wings level towards the bank given, sink rate held by G, throttle idle, nose not above maxPitch.
	void Flare(FsAirplane &air,const double bank,const double vSpeed,const double maxPitch,const double dt);

	// On the ground: steer towards aim (a point ahead on the route), hold groundSpeed.  Above the speed the
	// brakes come on, harder the more it is over.
	void Taxi(FsAirplane &air,const YsVec3 &aim,const double groundSpeed,const double dt);
	void Hold(FsAirplane &air,const double dt);  // Stopped, brakes on
	// Take-off roll: full power (afterburner if asked), steer at aim, raise the nose to pitch (0 = keep it down).
	void TakeOffRoll(FsAirplane &air,const YsVec3 &aim,const YSBOOL afterburner,const double pitch,const double dt);

	void SetSpoiler(const double s);
	void SetGearFlap(const double gear,const double flap);

	// Bank for a coordinated turn that brings the flight path onto aim (pure pursuit: the arc through aim).
	static double BankToward(const FsAirplane &air,const YsVec3 &aim,const double maxBank);
	static double GroundSpeed(const FsAirplane &air);
	static double BankRateLimit(void); // Shared with bounded terrain prediction.

	double GetThrottle(void) const;
	double GetBrake(void) const;

private:
	double bank,g,pitch;
	double throttle,throttleTrim;
	double rudder,brake,spoiler;
	double gear,flap;

	void Approach(double &value,const double target,const double ratePerSec,const double dt);
	void ApplyCommon(FsAirplane &air);
};

/* } */
#endif
