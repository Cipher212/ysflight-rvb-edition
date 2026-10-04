#include <ysclass.h>

#include "fs.h"
#include "fsrvbhands.h"

// RvB: see fsrvbhands.h (YSFlight RvB Edition, 2026-10-01).
// Signs follow YS: bank and heading + = left (counter-clockwise seen from above), rudder + = nose left.

static const double FSRVB_BANK_RATE=YsDegToRad(75.0);   // rad/s: how fast the hands roll
static const double FSRVB_BANK_EASE=4.0;                // 1/s: slows the roll near the wanted bank
static const double FSRVB_G_RATE=3.0;                   // G/s
static const double FSRVB_VSPEED_GAIN=0.12;             // G per m/s of vertical speed error
static const double FSRVB_THROTTLE_RATE=0.8;            // per s
static const double FSRVB_SPEED_GAIN=0.06;              // throttle per m/s of speed error
static const double FSRVB_TRIM_GAIN=0.02;               // throttle trim per (m/s * s)
static const double FSRVB_SPOILER_ON=8.0;               // m/s over the speed: spoilers out
static const double FSRVB_SPOILER_OFF=2.0;              // m/s over the speed: spoilers in again
static const double FSRVB_SPOILER_RATE=1.5;             // per s
static const double FSRVB_RUDDER_RATE=3.0;              // per s, on the ground
static const double FSRVB_STEER_ANGLE_GAIN=1.0/YsDegToRad(60.0);  // extra rudder per rad off the aim (slow taxi)
static const double FSRVB_TAXI_MAX_THROTTLE=0.7;
static const double FSRVB_BRAKE_GAIN=0.5;               // brake per m/s over the speed
static const double FSRVB_BRAKE_MIN=0.15;
static const double FSRVB_PITCH_RATE=YsDegToRad(4.0);   // rad/s: rotation on the take-off roll

FsRvbHands::AirIntent::AirIntent()
{
	bank=0.0;
	vSpeed=0.0;
	speed=100.0;
	gMax=4.0;
	gMin=-0.5;
	afterburner=YSFALSE;
	spoilerForSpeed=YSTRUE;
	spoiler=YSFALSE;
	gear=0.0;
	flap=0.0;
	idle=YSFALSE;
}

FsRvbHands::FsRvbHands()
{
	bank=0.0;
	g=1.0;
	pitch=0.0;
	throttle=0.5;
	throttleTrim=0.5;
	rudder=0.0;
	brake=0.0;
	spoiler=0.0;
	gear=0.0;
	flap=0.0;
}

void FsRvbHands::Reset(const FsAirplane &air)
{
	// Start from where the controls are, so taking over never jumps.
	bank=air.GetAttitude().b();
	g=air.Prop().GetG();
	pitch=air.GetAttitude().p();
	throttle=air.Prop().GetThrottle();
	throttleTrim=throttle;
	rudder=0.0;
	brake=(YSTRUE==air.Prop().GetBrake() ? 1.0 : 0.0);
	spoiler=air.Prop().GetSpoiler();
	gear=air.Prop().GetLandingGear();
	flap=air.Prop().GetFlap();
}

void FsRvbHands::Approach(double &value,const double target,const double ratePerSec,const double dt)
{
	const double step=ratePerSec*dt;
	value=(target>value ? YsSmaller(target,value+step) : YsGreater(target,value-step));
}

// YSFlight RvB Edition, 2026-10-03: use the hands' roll limit in terrain prediction.
/* static */ double FsRvbHands::BankRateLimit(void)
{
	return FSRVB_BANK_RATE;
}

double FsRvbHands::GetThrottle(void) const
{
	return throttle;
}

double FsRvbHands::GetBrake(void) const
{
	return brake;
}

void FsRvbHands::SetSpoiler(const double s)
{
	spoiler=s;
}

void FsRvbHands::SetGearFlap(const double gearIn,const double flapIn)
{
	gear=gearIn;
	flap=flapIn;
}

/* static */ double FsRvbHands::GroundSpeed(const FsAirplane &air)
{
	// YS GetVelocity is the airspeed; on the ground the wind would make a parked jet "move".
	if(YsTolerance<air.prevDt)
	{
		return (air.GetPosition()-air.prevPos).GetLengthXZ()/air.prevDt;
	}
	return 0.0;
}

/* static */ double FsRvbHands::BankToward(const FsAirplane &air,const YsVec3 &aim,const double maxBank)
{
	// Track direction (not the nose), so a crab or sideslip does not fool the turn.
	YsVec3 vel;
	air.Prop().GetVelocity(vel);
	vel.SetY(0.0);
	const double v=vel.GetLength();
	if(v<1.0)
	{
		return 0.0;
	}
	const double trackH=atan2(-vel.x(),vel.z());
	YsVec3 rel=aim-air.GetPosition();
	rel.SetY(0.0);
	const double dist=rel.GetLength();
	if(dist<1.0)
	{
		return 0.0;
	}
	rel.RotateXZ(-trackH);  // Into the track frame: z ahead, x to the side
	const double alpha=atan2(-rel.x(),rel.z());  // + = aim is to the left
	if(YsPi/2.0<fabs(alpha))
	{
		return (0.0<alpha ? maxBank : -maxBank);
	}
	const double curvature=2.0*sin(alpha)/dist;
	const double bnk=atan(v*v*curvature/FsGravityConst);
	return YsBound(bnk,-maxBank,maxBank);
}

void FsRvbHands::ApplyCommon(FsAirplane &air)
{
	air.Prop().SetGear(gear);
	air.Prop().SetFlap(flap);
	air.Prop().SetSpoiler(spoiler);
	air.Prop().SetBrake(brake);
}

void FsRvbHands::Fly(FsAirplane &air,const AirIntent &in,const double dt)
{
	air.Prop().NeutralDirectAttitudeControl();
	air.Prop().TurnOffSpeedController();

	// Roll: rate-limited, easing in near the wanted bank
	const double want=bank+(in.bank-bank)*YsSmaller(1.0,FSRVB_BANK_EASE*dt*4.0);
	Approach(bank,want,YsSmaller(FSRVB_BANK_RATE,fabs(in.bank-bank)*FSRVB_BANK_EASE+YsDegToRad(5.0)),dt);
	air.Prop().BankController(bank);

	// Pull: the G that keeps the turn and moves the vertical speed towards the wanted one
	YsVec3 vel;
	air.Prop().GetVelocity(vel);
	const double c=cos(air.GetAttitude().b());
	double gWant=(1.0+(in.vSpeed-vel.y())*FSRVB_VSPEED_GAIN)/YsGreater(0.2,c);
	gWant=YsBound(gWant,in.gMin,in.gMax);
	Approach(g,gWant,FSRVB_G_RATE,dt);
	air.Prop().GController(g);
	air.Prop().SetRudder(0.0);
	air.Prop().SmartRudder(dt);

	// Throttle with a slow trim, spoilers when well over the speed
	const double v=air.Prop().GetVelocity();
	const double err=in.speed-v;
	double thrWant=0.0;
	if(YSTRUE!=in.idle)
	{
		throttleTrim=YsBound(throttleTrim+err*FSRVB_TRIM_GAIN*dt,0.0,1.0);
		thrWant=YsBound(throttleTrim+err*FSRVB_SPEED_GAIN,0.0,1.0);
	}
	Approach(throttle,thrWant,FSRVB_THROTTLE_RATE,dt);
	air.Prop().SetThrottle(throttle);
	air.Prop().SetAfterburner(YSTRUE==in.afterburner && 0.99<throttle ? YSTRUE : YSFALSE);

	double spoilerWant=(0.5<spoiler ? 1.0 : 0.0);
	if(YSTRUE==in.spoiler)
	{
		spoilerWant=1.0;
	}
	else if(YSTRUE!=in.spoilerForSpeed || v<in.speed+FSRVB_SPOILER_OFF)
	{
		spoilerWant=0.0;
	}
	else if(v>in.speed+FSRVB_SPOILER_ON)
	{
		spoilerWant=1.0;
	}
	Approach(spoiler,spoilerWant,FSRVB_SPOILER_RATE,dt);
	gear=in.gear;
	flap=in.flap;
	brake=0.0;
	ApplyCommon(air);
}

void FsRvbHands::Flare(FsAirplane &air,const double bankWant,const double vSpeed,const double maxPitch,const double dt)
{
	air.Prop().NeutralDirectAttitudeControl();
	air.Prop().TurnOffSpeedController();
	Approach(bank,bankWant,FSRVB_BANK_RATE*0.5,dt);
	air.Prop().BankController(bank);

	YsVec3 vel;
	air.Prop().GetVelocity(vel);
	const double glide=atan2(-vel.y(),YsGreater(1.0,sqrt(vel.x()*vel.x()+vel.z()*vel.z())));
	const double gWant=YsBound(1.0+(vSpeed-vel.y())*FSRVB_VSPEED_GAIN,0.9,1.3);
	Approach(g,gWant,FSRVB_G_RATE,dt);
	air.Prop().GController(g);
	air.Prop().SetGControllerAOALimit(glide-YsDegToRad(2.0),maxPitch+glide);
	air.Prop().SetRudder(0.0);
	air.Prop().SmartRudder(dt);

	Approach(throttle,0.0,FSRVB_THROTTLE_RATE*2.0,dt);
	throttleTrim=throttle;
	air.Prop().SetThrottle(throttle);
	air.Prop().SetAfterburner(YSFALSE);
	brake=0.0;
	ApplyCommon(air);
}

void FsRvbHands::Taxi(FsAirplane &air,const YsVec3 &aim,const double groundSpeed,const double dt)
{
	air.Prop().NeutralDirectAttitudeControl();
	air.Prop().TurnOffController();
	air.Prop().TurnOffSpeedController();
	air.Prop().SetElevator(0.0);
	air.Prop().SetAfterburner(YSFALSE);

	// Steer: the arc through the aim point (pure pursuit), as a yaw rate the nose wheel can give
	const double v=GroundSpeed(air);
	YsVec3 rel=aim-air.GetPosition();
	rel.SetY(0.0);
	rel.RotateXZ(-air.GetAttitude().h());
	const double alpha=atan2(-rel.x(),rel.z());
	const double dist=YsGreater(1.0,rel.GetLength());
	const double yawRateWant=v*2.0*sin(alpha)/dist;
	const double yawRateMax=YsGreater(0.2,fabs(air.Prop().GetGroundYawSpeed(1.0)));
	const double rudWant=YsBound(yawRateWant/yawRateMax+alpha*FSRVB_STEER_ANGLE_GAIN*(v<5.0 ? 1.0 : 0.2),-1.0,1.0);
	Approach(rudder,rudWant,FSRVB_RUDDER_RATE,dt);
	air.Prop().SetRudder(rudder);

	// Speed: brake when over, throttle with a slow trim when under
	const double err=groundSpeed-v;
	double thrWant=0.0,brakeWant=0.0;
	if(err<-0.5 || groundSpeed<0.3)
	{
		brakeWant=(groundSpeed<0.3 ? 1.0 : YsBound(-err*FSRVB_BRAKE_GAIN,FSRVB_BRAKE_MIN,1.0));
		throttleTrim=YsGreater(0.0,throttleTrim-0.1*dt);
	}
	else
	{
		throttleTrim=YsBound(throttleTrim+err*FSRVB_TRIM_GAIN*dt,0.0,FSRVB_TAXI_MAX_THROTTLE);
		thrWant=YsBound(throttleTrim+err*FSRVB_SPEED_GAIN,0.0,FSRVB_TAXI_MAX_THROTTLE);
	}
	Approach(throttle,thrWant,FSRVB_THROTTLE_RATE*2.0,dt);
	brake=brakeWant;  // The brake itself is quick on a real jet, and late braking is what goes wrong
	air.Prop().SetThrottle(throttle);
	ApplyCommon(air);
}

void FsRvbHands::Hold(FsAirplane &air,const double dt)
{
	air.Prop().NeutralDirectAttitudeControl();
	air.Prop().TurnOffController();
	air.Prop().TurnOffSpeedController();
	air.Prop().SetElevator(0.0);
	air.Prop().SetAfterburner(YSFALSE);
	Approach(rudder,0.0,FSRVB_RUDDER_RATE,dt);
	air.Prop().SetRudder(rudder);
	Approach(throttle,0.0,FSRVB_THROTTLE_RATE*2.0,dt);
	throttleTrim=0.0;
	air.Prop().SetThrottle(throttle);
	brake=1.0;
	ApplyCommon(air);
}

void FsRvbHands::TakeOffRoll(FsAirplane &air,const YsVec3 &aim,const YSBOOL afterburner,const double pitchWant,const double dt)
{
	air.Prop().NeutralDirectAttitudeControl();
	air.Prop().TurnOffSpeedController();

	const double v=GroundSpeed(air);
	YsVec3 rel=aim-air.GetPosition();
	rel.SetY(0.0);
	rel.RotateXZ(-air.GetAttitude().h());
	const double alpha=atan2(-rel.x(),rel.z());
	const double dist=YsGreater(1.0,rel.GetLength());
	const double yawRateMax=YsGreater(0.2,fabs(air.Prop().GetGroundYawSpeed(1.0)));
	const double rudWant=YsBound(v*2.0*sin(alpha)/dist/yawRateMax,-1.0,1.0);
	Approach(rudder,rudWant,FSRVB_RUDDER_RATE,dt);
	air.Prop().SetRudder(rudder);

	if(0.0<pitchWant)
	{
		Approach(pitch,pitchWant,FSRVB_PITCH_RATE,dt);
		air.Prop().BankController(0.0);
		air.Prop().PitchController(pitch);
	}
	else
	{
		pitch=air.GetAttitude().p();
		air.Prop().TurnOffController();
		air.Prop().SetElevator(0.0);
	}

	Approach(throttle,1.0,FSRVB_THROTTLE_RATE*1.5,dt);
	throttleTrim=throttle;
	air.Prop().SetThrottle(throttle);
	air.Prop().SetAfterburner(YSTRUE==afterburner && 0.99<throttle ? YSTRUE : YSFALSE);
	brake=0.0;
	ApplyCommon(air);
	bank=0.0;
	g=1.0;
}
