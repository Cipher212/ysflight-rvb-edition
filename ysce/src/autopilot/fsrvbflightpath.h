#ifndef FSRVBFLIGHTPATH_IS_INCLUDED
#define FSRVBFLIGHTPATH_IS_INCLUDED

// Bounded terrain sampling for the bank actually commanded by the pilot's hands.
// Shared with the native fixture so tests exercise the production predictor.
// YSFlight RvB Edition, 2026-10-03.
#include <algorithm>
#include <cmath>
#include <initializer_list>

class FsRvbFlightPath
{
public:
	static constexpr double LOOK_TIME_MAX=8.0;
	static constexpr double CORRIDOR_HALF_WIDTH=60.0;
	static constexpr double ROLL_DELAY=1.0;
	static constexpr int STEPS=32;
	class Input
	{
	public:
		double x,z,speed,heading,bank,targetBank;
		double maxBank,rollRate,gravity,clearance,lookTime;
	};

	// Samples both immediate response and a one-second delayed roll. Neither
	// assumes that the aircraft can point at a distant aim instantly.
	template <class Elevation>
	static double TerrainFloor(const Input &in,Elevation elevation)
	{
		const double horizon=std::max(0.0,std::min(LOOK_TIME_MAX,in.lookTime));
		const double speed=std::max(1.0,in.speed);
		const double limit=std::max(0.0,std::min(std::acos(0.25),std::fabs(in.maxBank))); // holding intent <=4 G
		const double target=std::max(-limit,std::min(limit,in.targetBank));
		double floor=elevation(in.x,in.z)+in.clearance;
		for(double delay : {0.0,ROLL_DELAY})
		{
			double x=in.x,z=in.z,heading=in.heading;
			double bank=std::max(-limit,std::min(limit,in.bank));
			const int steps=STEPS;
			const double dt=horizon/steps;
			for(int i=0; i<steps; ++i)
			{
				const double oldBank=bank;
				if((i+1)*dt>delay)
				{
					const double roll=std::max(0.0,in.rollRate)*dt;
					bank+=std::max(-roll,std::min(roll,target-bank));
				}
				const double omega=in.gravity*std::tan((oldBank+bank)*0.5)/speed;
				const double midHeading=heading+omega*dt*0.5;
				x-=std::sin(midHeading)*speed*dt;
				z+=std::cos(midHeading)*speed*dt;
				heading+=omega*dt;
				for(double flank : {-CORRIDOR_HALF_WIDTH,0.0,CORRIDOR_HALF_WIDTH})
				{
					const double ground=elevation(x+std::cos(heading)*flank,z+std::sin(heading)*flank);
					floor=std::max(floor,ground+in.clearance);
				}
			}
		}
		return floor;
	}

	// Evaluate both achievable escape arcs, rather than one unreachable point
	// 45 degrees away. Keep the current turn on a tie to avoid alternating banks.
	template <class Elevation>
	static double EscapeBank(const Input &in,Elevation elevation)
	{
		Input left=in,right=in;
		// Reserve lift for climbing under the holding intent's 4 G limit.
		const double escapeBank=std::min(std::fabs(in.maxBank),std::acos(1.0/3.0));
		left.targetBank=escapeBank;
		right.targetBank=-escapeBank;
		const double leftFloor=TerrainFloor(left,elevation);
		const double rightFloor=TerrainFloor(right,elevation);
		if(std::fabs(leftFloor-rightFloor)<1.0)
		{
			return (in.targetBank>=0.0 ? escapeBank : -escapeBank);
		}
		return (leftFloor<rightFloor ? escapeBank : -escapeBank);
	}
};

#endif
