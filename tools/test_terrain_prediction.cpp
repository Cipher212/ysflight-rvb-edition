// Deterministic fixtures exercise the header used by FsRvbArrival, not a Python replica.
#include "fsrvbflightpath.h"
#include <cassert>
#include <iostream>

static const double DEG=0.017453292519943295;

static FsRvbFlightPath::Input input()
{
	return {0.0,0.0,108.0,0.0,0.0,-40.0*DEG,40.0*DEG,75.0*DEG,9.80665,40.0,8.0};
}

int main()
{
	const auto ridge=[](double x,double z)
	{
		return (-200.0<=x && x<=400.0 && 350.0<=z && z<=700.0 ? 250.0 : 0.0);
	};
	auto in=input();
	assert(FsRvbFlightPath::TerrainFloor(in,ridge)==290.0);
	for(int i=0; i<=10; ++i)
	{
		assert(ridge(i*150.0,0.0)==0.0);
	}
	std::cout << "PASS ridge on actual turning path\n";

	const auto sideRidge=[](double x,double z)
	{
		return (80.0<=x && x<=400.0 && 500.0<=z && z<=800.0 ? 250.0 : 0.0);
	};
	assert(FsRvbFlightPath::EscapeBank(in,sideRidge)>0.0);
	auto escaped=in;
	escaped.targetBank=40.0*DEG;
	assert(FsRvbFlightPath::TerrainFloor(escaped,sideRidge)==40.0);
	std::cout << "PASS escape compares reachable left/right arcs\n";

	// Closed-loop kinematic fixture uses the production escape selection and
	// roll/turn limits. It does not replace a full YS physics terrain soak.
	in=input();
	double y=160.0,minAgl=y;
	for(int i=0; i<80; ++i)
	{
		const double floor=FsRvbFlightPath::TerrainFloor(in,sideRidge);
		if(floor-y>100.0)
		{
			in.targetBank=FsRvbFlightPath::EscapeBank(in,sideRidge);
		}
		y+=std::max(0.0,std::min(25.0,(floor-y)/4.0))*0.1;
		in.bank+=std::max(-in.rollRate*0.1,std::min(in.rollRate*0.1,in.targetBank-in.bank));
		in.heading+=in.gravity*std::tan(in.bank)/in.speed*0.1;
		in.x-=std::sin(in.heading)*in.speed*0.1;
		in.z+=std::cos(in.heading)*in.speed*0.1;
		minAgl=std::min(minAgl,y-sideRidge(in.x,in.z));
	}
	assert(minAgl>=40.0);
	std::cout << "PASS fixture clearance " << minAgl << " m\n";

	in=input();
	in.targetBank=0.0;
	int calls=0;
	FsRvbFlightPath::TerrainFloor(in,[&calls](double,double){++calls;return 0.0;});
	assert(calls<=193);
	assert(FsRvbFlightPath::TerrainFloor(in,[](double,double){return 0.0;})==40.0);
	std::cout << "PASS bounded level/zero-bank prediction\n";

	in=input();
	in.bank=40.0*DEG;
	in.targetBank=-40.0*DEG;
	assert(std::isfinite(FsRvbFlightPath::TerrainFloor(in,ridge)));
	in.speed=0.0;
	assert(std::isfinite(FsRvbFlightPath::TerrainFloor(in,ridge)));
	std::cout << "PASS reversing bank and zero speed remain finite\n";
	return 0;
}
