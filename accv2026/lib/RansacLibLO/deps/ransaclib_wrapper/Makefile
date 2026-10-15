# =============================================================================
# Build the RansacLib LO Julia shim (libransaclib_jl.so)
#
# RansacLib is header-only (BSD-3, Sattler); the shim is a single translation
# unit. Dependencies: RansacLib headers (vendored at ../RansacLib) and Eigen
# (header-only; resolution order below). `Pkg.build("RansacLibLO")` (../build.jl)
# hands it Eigen_jll's include directory as EIGEN_INCLUDE.
# =============================================================================

RANSACLIB_INC ?= $(realpath ..)/RansacLib

# Eigen resolution: EIGEN_INCLUDE (Eigen_jll's, from ../build.jl, or set by
# hand) > system > local clone (`make eigen`).
EIGEN_CANDIDATES := $(EIGEN_INCLUDE) \
                    /usr/include/eigen3 \
                    $(CURDIR)/eigen-src
EIGEN_INC := $(firstword $(foreach d,$(EIGEN_CANDIDATES),$(if $(wildcard $(d)/Eigen/Core),$(d))))

CXX      ?= g++
CXXFLAGS := -std=c++17 -O3 -fPIC -Wall
TARGET   := libransaclib_jl.$(if $(filter Darwin,$(shell uname)),dylib,so)

.PHONY: all clean eigen

all: $(TARGET)

eigen:
ifeq ($(EIGEN_INC),)
	git clone --depth 1 --branch 3.4.0 https://gitlab.com/libeigen/eigen.git $(CURDIR)/eigen-src
endif

$(TARGET): julia_wrapper.cpp | eigen
	@test -d "$(RANSACLIB_INC)/RansacLib" || \
	  (echo "RansacLib headers not found at $(RANSACLIB_INC) — run deps/build.jl"; exit 1)
	$(eval EIGEN_INC := $(firstword $(foreach d,$(EIGEN_CANDIDATES),$(if $(wildcard $(d)/Eigen/Core),$(d)))))
	$(CXX) $(CXXFLAGS) -I$(RANSACLIB_INC) -I$(EIGEN_INC) -shared $< -o $@

clean:
	rm -rf $(TARGET) eigen-src
