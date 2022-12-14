#!/usr/bin/env bash
set -euo pipefail

function trap_sigint() {
    echo "trap is detected(sigint)"
	exit 1
}
trap trap_sigint sigint

function setup_molcas () {
	# Configure Molcas
	echo "Starting Molcas setup..."
	# Find the directory for the MOLCAS installation
	# (e.g. molcas84.tar.gz -> molcas84)
	MOLCAS_LICENSE=$(find "$SCRIPT_PATH/molcas" -maxdepth 1 -name "license*")
	MOLCAS_TARBALL=$(find "$SCRIPT_PATH/molcas" -maxdepth 1 -name "molcas*tar*")
	MOLCAS_TARBALL_NO_EXTENSION="$(echo "$MOLCAS_TARBALL" | awk -F'[/]' '{print $NF}' | sed 's/\.tar.*//')"

	# Now we can configure the Molcas package
	echo "Start configuring Molcas package"
	cp -f "$MOLCAS_LICENSE" "$MOLCAS"
	cp -f "$MOLCAS_TARBALL" "$MOLCAS"
	cd "$MOLCAS"
	tar -xf "$MOLCAS_TARBALL"
	# Check if the directory exists
	if [ ! -d "$MOLCAS_TARBALL_NO_EXTENSION" ]; then
		echo "ERROR: MOLCAS installation directory not found."
		echo "Please check the file name (Searched for '$MOLCAS_TARBALL_NO_EXTENSION' in the '$MOLCAS' directory). Exiting."
		exit 1
	fi

	# Configure the Molcas package
	cd "$MOLCAS/$MOLCAS_TARBALL_NO_EXTENSION"
	if [ -z "${XLIB:-}" ]; then
		echo "MOLCAS XLIB is empty..."
		export XLIB="-mkl"
		# export XLIB="-Wl,--no-as-needed -L${MKLROOT}/lib/intel64 -lmkl_gf_ilp64 -lmkl_core -lmkl_sequential -lpthread -lm -mkl"
		echo "MOLCAS XLIB is set to $XLIB"
	fi
	if [ -z "${MOLCAS_COMPILERPATH:-}" ]; then
		echo "MOLCAS_COMPILERPATH is empty..."
		MOLCAS_COMPILERPATH="$( which mpiifort | xargs dirname )"
		echo "MOLCAS_COMPILERPATH is set to $MOLCAS_COMPILERPATH"
	fi
	./fetch && ./configure -compiler intel -parallel -parallel -blas MKL -path "$MOLCAS_COMPILERPATH"
	ret=$?
	if [ $ret -ne 0 ]; then
		echo "ERROR: Molcas setup failed."
		echo "Please check the log file '$SCRIPT_PATH/molcas-setup.log' for more information."
		exit 1
	fi

	# Setup modulefiles
	cp -f "$SCRIPT_PATH/molcas/molcas" "${MODULEFILES}"
	echo "prepend-path  PATH	${HOME}/bin" >> "${MODULEFILES}/utchem"

	# Build MOLCAS
	cd "$MOLCAS/$MOLCAS_TARBALL_NO_EXTENSION"
	make 2>&1 | tee "$SCRIPT_PATH/molcas-make.log"
	ret=$?
	if [ $ret -ne 0 ]; then
		echo "ERROR: Molcas make failed with exit code $ret"
		exit $ret
	fi

	cd "$SCRIPT_PATH"
}

function check_one_file_only () {
    if [ "$( echo "$FILE_NAMES" | wc -l )" -gt 1 ]; then
        echo "ERROR: Detected multiple $PROGRAM_NAME ${FILE_TYPE}s in $SCRIPT_PATH/$PROGRAM_NAME directory."
        echo "       Searched for $FILE_TYPE files named '$FIND_CONDITION'."
        echo "       Please remove all but one file."
        echo "Detected ${FILE_TYPE}s:"
        echo "$FILE_NAMES"
        echo "Exiting."
        exit 1
    fi
}

function test_utchem () {
	set +e
	echo "Start testing UTChem..."
	failed_test_files=()
	tests_count=0
	for TEST_SCRIPT_PATH in $(find "$UTCHEM_BUILD_DIR" -name "test.sh")
	do
		# DFT_GEOPT="$(echo "$TEST_SCRIPT_PATH" | grep dft.geopt)"
		# if [ "$DFT_GEOPT" ]; then
		# 	echo "Skipping test script $TEST_SCRIPT_PATH"
		# 	continue
		# fi
		HF="$(echo "$TEST_SCRIPT_PATH" | grep Hartree)"
		DFT="$(echo "$TEST_SCRIPT_PATH" | grep rtddft)"
		if [ "$HF" ] || [ "$DFT" ]; then
			TEST_SCRIPT_DIR="$(dirname "$TEST_SCRIPT_PATH")"
			cd "$TEST_SCRIPT_DIR"
			echo "Start Running a test script under: ${TEST_SCRIPT_DIR}"
			SCRATCH="scratch"
			TEST_RESULTS="test-results"
			mkdir -p ${SCRATCH} ${TEST_RESULTS}
			for ii in *.ut
			do
				echo
				echo "=================================================================="
				echo "Testing... $ii"
				date
				OUTPUT="${ii}out"
				echo "Output file: ${OUTPUT}"
				echo "../../boot/utchem -n ${SETUP_NPROCS} -w ${SCRATCH} $ii >& ${TEST_RESULTS}/$OUTPUT"

				../../boot/utchem -n "${SETUP_NPROCS}" -w "${SCRATCH} $ii" > "${TEST_RESULTS}/$OUTPUT" 2>&1
				date
				echo "End running test script"

				#<< "#COMMENT"
				tests_count=$(( $tests_count+1 ))
				# a.utout.nproc=1 a.utout.nproc=2 a.utout.nproc=4 => a.utout.nproc=4
				reference_output=$( ls "$TEST_SCRIPT_DIR/$OUTPUT" | tail -n 1 )
				result_output="$TEST_SCRIPT_DIR/${TEST_RESULTS}/$OUTPUT"
				references=($(grep "Total Energy.*=" "$reference_output" | awk '{for(i = 1; i <= NF - 2; i++){printf $i}printf " " $NF " "}'))
				results=($(grep "Total Energy.*=" "$result_output" | awk '{for(i = 1; i <= NF - 2; i++){printf $i}printf " " $NF " "}'))

				echo "Start checking test results for $reference_output and $result_output..."
				echo "references: " "${references[@]}"
				echo "results: " "${results[@]}"
				if [ ${#references[@]} -ne ${#results[@]} ] ; then
					failed_test_files+=("$result_output")
					echo "ERROR: references and results are not same length"
					echo "So we don't evaluate the results of Total Energy"
					echo "references:" "${references[@]}"
					echo "results:" "${results[@]}"
					continue
				fi

				for ((i = 1; i < ${#references[@]}; i+=2));
				do
					diff=$( echo "${references[$i]} ${results[$i]}" | awk '{printf $1 - $2}' )
					absdiff=${diff#-}
					threshold=1e-7
					is_pass_test=$( echo "${absdiff} ${threshold}" | awk '{if($1 <= $2) {print "YES"} else {print "NO"}}' )
					all_test_passed="YES"
					echo "Checking abs(reference - result): ${absdiff} <= ${threshold} ? ... ${is_pass_test}"

					if [ "$is_pass_test" = "YES" ] ; then
						echo "TEST PASSED"
					else
						all_test_passed="NO"
						echo "ERROR: TEST FAILED"
						echo "threshold = $threshold"
						echo "Difference between the reference and the result in the calculation of ${references[$((i-1))]} is greater than the threshold."
						echo "references = ${references[$i]} Hartree"
						echo "results = ${results[$i]} Hartree"
						echo "abs(diff) = ${absdiff} Hartree"
						failed_test_files+=("$result_output")
					fi
				done
				if [ $all_test_passed = "YES" ] ; then
					echo "ALL TESTS PASSED for $result_output"
				else
					echo "ERROR: SOME TESTS FAILED for $result_output"
				fi
				#COMMENT
				echo "End checking test results for $reference_output and $result_output..."
				echo "=================================================================="
				echo
			done
			echo "Finished Running test scripts under: ${TEST_SCRIPT_DIR}"
		fi
	done
	echo "Finished testing UTChem"
	echo "------------------------------------------------------------------"
	echo "Summary of UTChem tests"
	echo "ALL TESTS: ${tests_count}"
	echo "FAILED TESTS: ${#failed_test_files[@]}"
	if [ ${#failed_test_files[@]} -ne 0 ]; then
		echo "ERROR: SOME TESTS FAILED"
		echo "FAILED TESTS:"
		for failed_test in "${failed_test_files[@]}"
		do
			echo "  $failed_test"
		done
	else
		echo "ALL TESTS PASSED!"
	fi
	echo "------------------------------------------------------------------"
	set -e
}

function setup_utchem () {
	echo "Start setup UTChem..."
	OMPI_VERSION="$OPENMPI4_VERSION"
	set_ompi_path # set OpenMPI PATH

	UTCHEM_PATCH=$(find "$SCRIPT_PATH/utchem" -maxdepth 1 -type d -name patches)
	UTCHEM_TARBALL=$(find "$SCRIPT_PATH/utchem" -maxdepth 1 -name "utchem*tar*")
	cp -f "${UTCHEM_TARBALL}" "${UTCHEM}"
	cp -rf "${UTCHEM_PATCH}" "${UTCHEM}"
	PATCHDIR=$(find "$SCRIPT_PATH/utchem" -maxdepth 1 -type d -name patches)

	# Unzip utchem.tar file
	cd "${UTCHEM}"
	mkdir -p "${UTCHEM}/utchem"
	tar -xf "${UTCHEM_TARBALL}" -C "${UTCHEM}/utchem" --strip-components 1
    UTCHEM_BUILD_DIR="${UTCHEM}/utchem"
	GA4="${UTCHEM_BUILD_DIR}/ga4-0-2"

	# File location of Patch files and files to patch
	GAMAKEFILE="${GA4}/ga++/GNUmakefile"
	GAPATCH="${PATCHDIR}/ga_patch"
	GLOBALMAKEFILE="${GA4}/global/GNUmakefile"
	GLOBALPATCH="${PATCHDIR}/global_patch"
	GACONFIGFILE="${GA4}/config/makefile.h"
	GACONFIGPATCH="${PATCHDIR}/makefile.h.patch"

	# Patch files (To run "make" command normally)
	patch "${GAMAKEFILE}" "${GAPATCH}"
	patch "${GLOBALMAKEFILE}" "${GLOBALPATCH}"
	patch "${GACONFIGFILE}" "${GACONFIGPATCH}"

	# Use ifort, gcc and g++ to build utchem (64bit linux machine)
	#   If you want to build utchem using gfortran, gcc and g++ (integer8),
	#       change linux_ifort_x86_64_i8.config.sh.in to linux_gcc4_x86_64_i8_config.sh.in and
	#       change linux_ifort_x86_64_i8.makeconfig.in to linux_gcc4_x86_64_i8_makeconfig.in.
	cd "${UTCHEM_BUILD_DIR}/config"
	cp -f linux_mpi_ifort_x86_64_i8.config.sh.in linux_ifc.config.sh.in
	cp -f linux_mpi_ifort_x86_64_i8.makeconfig.in linux_ifc.makeconfig.in


	# Configure utchem
	#   If your system don't have python in /usr/bin, you have to install python 2.x.x to your system
	#   and add the path where you installed python.
	#   (e.g. If you installed a python executable file at /home/users/username/python)
	#   ./configure --python=/home/users/username/python
	cd "${UTCHEM_BUILD_DIR}"
	UTCHEM_MPI="$(dirname "$( which mpif77 | xargs dirname )")"
	./configure --mpi="$UTCHEM_MPI" --python=python2 2>&1 | tee "$SCRIPT_PATH/utchem-make.log"

	# Make utchem (${UTCHEM_BUILD_DIR}/boot/utchem is executable file)
	make 2>&1 | tee "$SCRIPT_PATH/utchem-make.log"

	# Setup modulefiles
	cp -f "$SCRIPT_PATH/utchem/utchem" "${MODULEFILES}"
	echo "prepend-path  PATH	${UTCHEM_BUILD_DIR}/boot" >> "${MODULEFILES}/utchem"

	# Run test script
	test_utchem 2>&1 | tee "$SCRIPT_PATH/utchem-test.log"
	cd "$SCRIPT_PATH"

}

function run_dirac_testing () {
	echo "START DIRAC-${DIRAC_VERSION} test!!"
	TEST_NPROCS=${DIRAC_NPROCS}
    mkdir -p "$DIRAC_BASEDIR"/test_results
    export DIRAC_MPI_COMMAND="mpirun -np $TEST_NPROCS"
	set +e
	make test
	set -e
	cp -f Testing/Temporary/LastTest.log "$DIRAC_BASEDIR/test_results"
	if [ -f Testing/Temporary/LastTestsFailed.log ]; then
		cp -f Testing/Temporary/LastTestsFailed.log "$DIRAC_BASEDIR/test_results"
	else
		echo "NO TESTS FAILED" > "$DIRAC_BASEDIR/test_results/LastTestsFailed.log"
	fi
}

function build_dirac () {
	echo "DIRAC NRPOCS : $DIRAC_NPROCS"
	DIRAC_BASEDIR="$DIRAC/$DIRAC_VERSION"
	cp -rf "$SCRIPT_PATH/dirac/$DIRAC_VERSION" "$DIRAC"
	cd "$DIRAC_BASEDIR"
	# Unzip tarball
	DIRAC_TAR="DIRAC-$DIRAC_VERSION-Source.tar.gz"
	tar xf "$DIRAC_TAR"
	cd "DIRAC-$DIRAC_VERSION-Source"
	# Patch DIRAC integer(4) to integer(8) (max_mem)
	PATCH_MEMCONTROL="$DIRAC_BASEDIR/diff_memcon"
	patch -p0 --ignore-whitespace < "$PATCH_MEMCONTROL"
	# Configure DIRAC
	./setup --mpi --fc=mpif90 --cc=mpicc --cxx=mpicxx --mkl=parallel --int64 --extra-fc-flags="-xHost"  --extra-cc-flags="-xHost"  --extra-cxx-flags="-xHost" --prefix="$DIRAC_BASEDIR"
	cd build
	# Build DIRAC
	make -j "$DIRAC_NPROCS" && make install
	# Setup modulefiles
	DIRAC_MODULE_DIR="${MODULEFILES}/dirac"
	mkdir -p "${DIRAC_MODULE_DIR}"
	cp -f "${DIRAC_BASEDIR}/${DIRAC_VERSION}" "${DIRAC_MODULE_DIR}"
	echo "module load openmpi/${OMPI_VERSION}-intel" >> "${DIRAC_MODULE_DIR}/${DIRAC_VERSION}"
	echo "prepend-path  PATH	${DIRAC_BASEDIR}/share/dirac" >> "${DIRAC_MODULE_DIR}/${DIRAC_VERSION}"
	run_dirac_testing
	cd "$SCRIPT_PATH"
}

function set_ompi_path () {
	PATH="${OPENMPI}/${OMPI_VERSION}-intel/bin:$PATH"
	LIBRARY_PATH="${OPENMPI}/${OMPI_VERSION}-intel/lib:$LIBRARY_PATH"
	LD_LIBRARY_PATH="${OPENMPI}/${OMPI_VERSION}-intel/lib:$LD_LIBRARY_PATH"
}

function setup_dirac () {
	cd "$SCRIPT_PATH"
	pyenv global "$PYTHON3_VERSION"
	DIRAC_SCR="$HOME/dirac_scr"
	mkdir -p "$DIRAC_SCR"
	DIRAC_NPROCS=$(( $SETUP_NPROCS / $dirac_counts ))
	OMPI_VERSION="$OPENMPI4_VERSION" # DIRAC 19.0 and 21.1 use this version of OpenMPI
	set_ompi_path # set OpenMPI PATH
	for DIRAC_VERSION in $INSTALL_DIRAC_VERSIONS; do
		if (( "$DIRAC_NPROCS" <= 1 )); then # Serial build
			echo "DIRAC will be built in serial mode."
			DIRAC_NPROCS=$SETUP_NPROCS
		    build_dirac 2>&1 | tee "dirac-$DIRAC_VERSION-build-result.log"
		else # Parallel build
			echo "DIRAC will be built in parallel mode."
			build_dirac 2>&1 | tee "dirac-$DIRAC_VERSION-build-result.log" &
		fi
	done
	wait
	cd "$SCRIPT_PATH"
}

function setup_python () {
	echo "Start python setup..."
	PYENVROOT="$INSTALL_PATH/.pyenv"
	SKIP_PYENV_INSTALL="Y"
	# if PYENVROOT exists, skip clone
	if [ ! -d "$PYENVROOT" ]; then
		git clone https://github.com/pyenv/pyenv.git "$PYENVROOT"
		SKIP_PYENV_INSTALL="N"
	fi
	export PYENV_ROOT="$INSTALL_PATH/.pyenv"
	export PATH="$PYENV_ROOT/bin:$PATH"
	eval "$(pyenv init -)"
	echo "$PYENV_ROOT , $INSTALL_PATH, skip? : $SKIP_PYENV_INSTALL" > "$SCRIPT_PATH/python-version.log" 2>&1
	if [ "$SKIP_PYENV_INSTALL" = "N" ]; then
		echo "export PYENV_ROOT=\"$PYENVROOT\"" >> "$HOME/.bashrc"
		echo "command -v pyenv >/dev/null || export PATH=\"$PYENVROOT/bin:\$PATH\"" >> "$HOME/.bashrc"
		echo 'eval "$(pyenv init -)"' >> "$HOME/.bashrc"
		export MAKE_OPTS="-j${SETUP_NPROCS}"
		pyenv install "$PYTHON2_VERSION"
		pyenv install "$PYTHON3_VERSION"
	fi
	pyenv global "$PYTHON2_VERSION"
	python -V >> "$SCRIPT_PATH/python-version.log" 2>&1
}

function setup_cmake () {
	echo "Start cmake setup..."
	mkdir -p "${CMAKE}"
	mkdir -p "${MODULEFILES}/cmake"
	# unzip cmake prebuild tarball
	tar -xf "${SCRIPT_PATH}/cmake/cmake-${CMAKE_VERSION}-linux-x86_64.tar.gz" -C "${CMAKE}"
	# ${CMAKE} ?????????????????????tarball???????????????????????????????????????tarball????????????????????????????????????????????????????????????????????????????????????
	cp -f "${SCRIPT_PATH}/cmake/cmake-${CMAKE_VERSION}-linux-x86_64.tar.gz" "${CMAKE}"
	cp -f "${SCRIPT_PATH}/cmake/${CMAKE_VERSION}" "${MODULEFILES}/cmake"
	echo "prepend-path    PATH    ${CMAKE}/cmake-${CMAKE_VERSION}-linux-x86_64/bin" >> "${MODULEFILES}/cmake/${CMAKE_VERSION}"
	echo "prepend-path    MANPATH ${CMAKE}/cmake-${CMAKE_VERSION}-linux-x86_64/man" >> "${MODULEFILES}/cmake/${CMAKE_VERSION}"
    # module load "cmake/${CMAKE_VERSION}" && cmake --version
	PATH=${CMAKE}/cmake-${CMAKE_VERSION}-linux-x86_64/bin:$PATH
	MANPATH=${CMAKE}/cmake-${CMAKE_VERSION}-linux-x86_64/man:$MANPATH
	cd "${SCRIPT_PATH}"
}

function build_openmpi() {
	echo "Start openmpi${OMPI_VERSION} setup..."
	# openmpi (8-byte integer)
	OMPI_TARBALL="${SCRIPT_PATH}/openmpi/openmpi-${OMPI_VERSION}.tar.bz2"
	OMPI_INSTALL_PREFIX="${OPENMPI}/${OMPI_VERSION}-intel"
	mkdir -p "${OPENMPI}/${OMPI_VERSION}-intel/build"
	tar -xf "${OMPI_TARBALL}" -C "${OPENMPI}/${OMPI_VERSION}-intel/build" --strip-components 1
	cd "${OPENMPI}/${OMPI_VERSION}-intel/build"
	./configure CC=icc CXX=icpc FC=ifort FCFLAGS=-i8  CFLAGS=-m64  CXXFLAGS=-m64 --enable-mpi-cxx --enable-mpi-fortran=usempi --prefix="${OMPI_INSTALL_PREFIX}"
	make -j "$OPENMPI_NPROCS" && make install && make check
	mkdir -p "${MODULEFILES}/openmpi"
	cp -f "${SCRIPT_PATH}/openmpi/${OMPI_VERSION}-intel" "${MODULEFILES}/openmpi"
	echo "prepend-path	PATH			${OMPI_INSTALL_PREFIX}/bin" >> "${MODULEFILES}/openmpi/${OMPI_VERSION}-intel"
	echo "prepend-path	LD_LIBRARY_PATH	${OMPI_INSTALL_PREFIX}/lib"	>> "${MODULEFILES}/openmpi/${OMPI_VERSION}-intel"
}

function setup_openmpi() {
	OPENMPI_NPROCS=$SETUP_NPROCS
	# Build OpenMPI 4.1.2 (intel fortran)
	OMPI_VERSION="$OPENMPI4_VERSION"
	build_openmpi 2>&1 | tee "openmpi-$OMPI_VERSION-build-result.log"
	wait
	cd "${SCRIPT_PATH}"
}

function set_process_number () {
	expr $SETUP_NPROCS / 2 > /dev/null 2>&1 || SETUP_NPROCS=1 # Is $SETUP_NPROCS a number? If not, set it to 1.
	MAX_NPROCS=$( cpuinfo  | grep "Processors(CPUs)" | awk '{print $3}' ) # Get the number of CPUs.
	if (( "$SETUP_NPROCS" < 0 )); then # invalid number of processes (negative numbers, etc.)
		echo "invalid number of processes: $SETUP_NPROCS"
		echo "use default number of processes: 1"
		SETUP_NPROCS=1
	elif (( "$SETUP_NPROCS > $MAX_NPROCS" )); then # number of processes is larger than the number of processors
		echo "number of processors you want to use: $SETUP_NPROCS"
		echo "number of processors you can use: $MAX_NPROCS"
		echo "use max number of processes: $MAX_NPROCS"
		SETUP_NPROCS=$MAX_NPROCS
	fi
}

function check_molcas_files () {

	MOLCAS_LICENSE=$(find "$SCRIPT_PATH/molcas" -maxdepth 1 -name "license*")
	MOLCAS_TARBALL=$(find "$SCRIPT_PATH/molcas" -maxdepth 1 -name "molcas*tar*")

	# Check if the license file and tarball exist
	if [ -z "${MOLCAS_LICENSE:-}" ]; then
		echo "ERROR: MOLCAS License file not found."
		echo "Please check the file name (Searched for 'license*' in the '$SCRIPT_PATH/molcas' directory). Exiting."
		exit 1
	fi
	if [ -z "${MOLCAS_TARBALL:-}" ]; then
		echo "ERROR: MOLCAS Tarball file not found."
		echo "Please check the file name (Searched for 'molcas*tar*' in the '$SCRIPT_PATH/molcas' directory). Exiting."
		exit 1
	fi

    # Check if the number of license file and tarball is one in the directory, respectively.
	FILE_NAMES="$MOLCAS_LICENSE"
	FILE_TYPE="license"
	FIND_CONDITION="license*"
	PROGRAM_NAME="molcas"
	check_one_file_only

	FILE_NAMES="$MOLCAS_TARBALL"
	FILE_TYPE="tarball"
	FIND_CONDITION="molcas*tar*"
	PROGRAM_NAME="molcas"
	check_one_file_only
}

function check_utchem_files () {

	UTCHEM_PATCH=$(find "$SCRIPT_PATH/utchem" -maxdepth 1 -type d -name patches)
	UTCHEM_TARBALL=$(find "$SCRIPT_PATH/utchem" -maxdepth 1 -name "utchem*tar*")

	# Check if the license file and tarball exist
	if [ ! -d "${UTCHEM_PATCH}" ]; then
		echo "ERROR: UTCHEM patches directory not found."
		echo "Please check the file name (Searched for 'patches' in the '$SCRIPT_PATH/utchem' directory). Exiting."
		exit 1
	fi
	if [ -z "${UTCHEM_TARBALL:-}" ]; then
		echo "ERROR: UTCHEM Tarball file not found."
		echo "Please check the file name (Searched for 'utchem*tar*' in the '$SCRIPT_PATH/utchem' directory). Exiting."
		exit 1
	fi

	# Check if the number of tarball is one in the directory.
	FILE_NAMES="$UTCHEM_TARBALL"
	FILE_TYPE="tarball"
	FIND_CONDITION="utchem*tar*"
	PROGRAM_NAME="utchem"
	check_one_file_only
}

function check_files_and_dirs () {
	if [ "$INSTALL_UTCHEM" == "YES" ] || [ "$INSTALL_DIRAC" == "YES" ]; then
		mkdir -p "${OPENMPI}"
	fi
	if [ "$INSTALL_MOLCAS" == "YES" ]; then
		mkdir -p "${MOLCAS}"
		check_molcas_files
	fi
	if [ "$INSTALL_DIRAC" == "YES" ]; then
		mkdir -p "${DIRAC}"
	fi
	if [ "$INSTALL_UTCHEM" == "YES" ]; then
		mkdir -p "${UTCHEM}"
		check_utchem_files
	fi
}

function check_install_programs () {
	if [ -z "${INSTALL_ALL:-}" ]; then
		INSTALL_ALL="NO"
	fi
	if [ "${INSTALL_ALL}" == "YES" ]; then
		INSTALL_DIRAC="YES"
		INSTALL_MOLCAS="YES"
		INSTALL_UTCHEM="YES"
	else
		PROGRAM_NAME="MOLCAS"
		if [ -z "${INSTALL_MOLCAS:-}" ]; then
			INSTALL_MOLCAS=$(whether_install_or_not)
		fi
		if [ ! "${INSTALL_MOLCAS}" = "YES" ] && [ ! "${INSTALL_MOLCAS}" = "NO" ]; then
			INSTALL_MOLCAS=$(whether_install_or_not)
		fi
		PROGRAM_NAME="DIRAC"
		if [ -z "${INSTALL_DIRAC:-}" ]; then
			INSTALL_DIRAC=$(whether_install_or_not)
		fi
		if [ ! "${INSTALL_DIRAC}" = "YES" ] && [ ! "${INSTALL_DIRAC}" = "NO" ]; then
			INSTALL_DIRAC=$(whether_install_or_not)
		fi
		if [ "${INSTALL_DIRAC}" = "YES" ]; then
			if [ -z "${INSTALL_DIRAC_VERSIONS:-}" ]; then
				INSTALL_DIRAC_VERSIONS="all"
		    fi
			if [ $INSTALL_DIRAC_VERSIONS = "all" ]; then
				cd "$SCRIPT_PATH/dirac"
				INSTALL_DIRAC_VERSIONS=$(ls -d -- *)
				cd "$SCRIPT_PATH"
			fi
			echo "You will install DIRAC versions: $INSTALL_DIRAC_VERSIONS"
			count=0
			for DIRAC_VERSION in $INSTALL_DIRAC_VERSIONS; do
			    count=$((count+1))
				if [ ! -d "$SCRIPT_PATH/dirac/$DIRAC_VERSION" ]; then
					echo "ERROR: DIRAC version $DIRAC_VERSION not found."
					echo "Please check the file name (Searched for '$DIRAC_VERSION' in the '$SCRIPT_PATH/dirac' directory). Exiting."
					exit 1
				fi
			done
			dirac_counts=$count
			echo "You will install $dirac_counts DIRAC versions."
		fi
		PROGRAM_NAME="UTCHEM"
		if [ -z "${INSTALL_UTCHEM:-}" ]; then
			INSTALL_UTCHEM=$(whether_install_or_not)
		fi
		if [ ! "${INSTALL_UTCHEM}" = "YES" ] && [ ! "${INSTALL_UTCHEM}" = "NO" ]; then
			INSTALL_UTCHEM=$(whether_install_or_not)
		fi
	fi

	INSTALL_PROGRAMS=("CMake (https://cmake.org/)")
	if [ "$INSTALL_MOLCAS" == "YES" ]; then
		INSTALL_PROGRAMS+=("Molcas (https://molcas.org/)")
	fi
	if [ "$INSTALL_DIRAC" == "YES" ]; then
		INSTALL_PROGRAMS+=("DIRAC (http://diracprogram.org/)")
	fi
	if [ "$INSTALL_UTCHEM" == "YES" ]; then
		INSTALL_PROGRAMS+=("UTChem (http://ccl.scc.kyushu-u.ac.jp/~nakano/papers/lncs-2660-84.pdf)")
	fi
	if [ "$INSTALL_UTCHEM" == "YES" ] || [ "$INSTALL_DIRAC" == "YES" ]; then
		INSTALL_PROGRAMS+=("OpenMPI (https://www.open-mpi.org/)")
	fi

	echo "The following programs will be installed:"
	for PROGRAM in "${INSTALL_PROGRAMS[@]}"
	do
		echo "$PROGRAM" | tee -a "${SCRIPT_PATH}/install-programs.log"
	done
	echo ""
}

function whether_install_or_not() {
    ANS="NO"
    read -p "Do you want to install $PROGRAM_NAME? (y/N)" yn
    case $yn in
        [Yy]* ) ANS="YES";;
        [Nn]* ) ANS="NO";;
        * ) ANS="NO";;
    esac
    echo $ANS
}

function set_install_path () {
	# Check if the variable is set
    if [ -z "${INSTALL_PATH:-}" ]; then
        echo "INSTALL_PATH is not set"
        INSTALL_PATH="${HOME}/software"
		echo "INSTALL_PATH is set to default install path: $INSTALL_PATH"
	fi

	# If overwrite is not set, change overwrite to NO
	if [ -z "${OVERWRITE:-}" ]; then
		OVERWRITE="NO"
	fi

    # Check if the path exists
	# OVERWRITE is set to YES if the user wants to overwrite the existing installation
	if [ "${OVERWRITE}" = "YES" ]; then
		echo "!!!!!!!!!!!!!!!!!!!!! Warning: OVERWRITE option selected YES !!!!!!!!!!!!!!!!!!!!!"
		echo "Warning: OVERWRITE option selected YES.  may overwrite the existing path! $INSTALL_PATH."
		echo "If you want to keep the existing path, do not set OVERWRITE to YES."
		echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
		ANS="NO"
		read -p "Do you want to set OVERWRITE option selected YES? (y/N)" yn
		case $yn in
			[Yy]* ) ANS="YES";;
			[Nn]* ) ANS="NO";;
			* ) ANS="NO";;
		esac
		echo "Your answer is $ANS"
		if [ "$ANS" = "NO" ]; then
			echo "OVERWRITE=YES was rejected by you. Exiting."
			exit 1
		fi
		echo "OVERWRITE option selected YES. may overwrite the existing path! $INSTALL_PATH."
	else
		if [ -d "$INSTALL_PATH" ]; then
			echo "$INSTALL_PATH is already exists"
			echo "Please remove the directory and run the script again or set the another path that does not exist."
			exit 1
		fi
	fi

	mkdir -p "${INSTALL_PATH}"
	INSTALL_PATH=$(cd "$(dirname "${INSTALL_PATH}")"; pwd)/$(basename "$INSTALL_PATH")
	echo "INSTALL_PATH is set to: $INSTALL_PATH"

}

function is_enviroment_modules_installed(){
	echo "Checking if the Enviroment Modules is already installed..."
	mkdir -p "${MODULEFILES}"
	if type module > /dev/null; then
		echo "Enviroment Modules is installed"
		echo "You can use module command to load the Modules under $MODULEFILES in your bashrc file."
		echo "(e.g. module use --append ${MODULEFILES})"
		module use --append "${MODULEFILES}"
		echo "module use --append ${MODULEFILES}" >> "$HOME/.bashrc"
		echo "Info: Add the modulefiles to your bashrc file. (module use --append ${MODULEFILES})"
	else
		echo "Enviroment Modules is not installed"
		echo "After Enviroment Modules is installed, you can use module command (c.f. http://modules.sourceforge.net/)"
		echo "You need to load the modules under $MODULEFILES in your bashrc file to use the modules configured in this script."
		echo "(e.g. module use --append ${MODULEFILES})"
	fi
}


function err_not_installed(){
	echo "==========================================================================="
	echo "Error: $1 is not installed"
	echo "$1 command is not installed. You must install $1 and try again."
	echo "==========================================================================="
	exit 1
}

function err_compiler(){
	echo "================================================================================"
	echo "$1 ($2) doesn't exist. You must install $2."
	echo "A simple setup is to install all packages Intel?? oneAPI Base Toolkit and Intel?? oneAPI HPC Toolkit."
	echo "But more specifically, you need to install the following packages:"
	echo "- Intel?? oneAPI Math Kernel Library (MKL) (included in Intel?? oneAPI Base Toolkit)"
	echo "- Intel?? oneAPI DPC++/C++ Compiler (included in Intel?? oneAPI Base Toolkit)"
	echo "- Intel?? MPI Library (included in Intel?? oneAPI HPC Toolkit)"
	echo "- Intel?? Fortran Compiler (included in Intel?? oneAPI HPC Toolkit)"
	echo "- Intel?? MPI Library (included in Intel?? oneAPI HPC Toolkit)"
	echo "When setting up oneAPI on a shared server,"
	echo "please refer to https://www.intel.com/content/www/us/en/develop/documentation/oneapi-programming-guide/top/oneapi-development-environment-setup/use-modulefiles-with-linux.html "
	echo "to set up with Enviroment Modules."
	echo "================================================================================"
	exit 1
}

function check_requirements(){
	variable=(/'a' 'b' 'c'/)
	echo "${variable[@]}" > /dev/null
	if ! type make > /dev/null; then
		err_not_installed "make"
		exit 1
	fi
	if ! type git > /dev/null; then
		err_not_installed "git"
		exit 1
	fi
	if ! type patch > /dev/null; then
		err_not_installed "patch"
		exit 1
	fi
	if ! type awk > /dev/null; then
		err_not_installed "awk"
		exit 1
	fi
	if ! type expr > /dev/null; then
		err_not_installed "expr"
		exit 1
	fi
	num=-1
	a=$(($num / 2))||1
	if ! type find > /dev/null; then
		err_not_installed "find"
		exit 1
	fi
	if ! type grep > /dev/null; then
		err_not_installed "grep"
		exit 1
	fi
	if ! type kill > /dev/null; then
		err_not_installed "kill"
		exit 1
	fi
	if ! type read > /dev/null; then
		err_not_installed "read"
		exit 1
	fi
	if ! type tar > /dev/null; then
		err_not_installed "tar"
		exit 1
	fi
	if ! type wc > /dev/null; then
		err_not_installed "wc"
		exit 1
	fi
	if ! type wget > /dev/null; then
		err_not_installed "wget"
		exit 1
	fi
	if ! type ifort > /dev/null; then
		err_compiler "Intel?? Fortran compiler" "ifort"
	fi
	if [ "${INSTALL_MOLCAS}" = "YES" ]; then
		if ! type mpiifort > /dev/null; then
			err_compiler "Intel?? MPI Library" "mpiifort"
		fi
	fi
	if ! type icc > /dev/null; then
		err_compiler "Intel?? C compiler" "icc"
	fi
	if ! type icpc > /dev/null; then
		err_compiler "Intel?? C++ Library" "icpc"
	fi
	if [ -z "${MKLROOT:-}" ]; then
		echo "==========================================================================="
		echo "Error: Environmental variable \$MKLROOT is not set."
		echo "You must set \$MKLROOT to the path of Intel?? oneAPI Math Kernel Library"
		echo "==========================================================================="
		exit 1
	fi
	echo "All requirements are configured. Proceeding..."

}

## Main ##
\unalias -a
umask 0022
SCRIPT_PATH=$(cd "$(dirname "$0")" && pwd)

# Check whether the user wants to install or not
check_install_programs

check_requirements

set_process_number
set_install_path

# Software path
MODULEFILES="${INSTALL_PATH}/modulefiles"
CMAKE="${INSTALL_PATH}/cmake"
OPENMPI="${INSTALL_PATH}/openmpi-intel"
DIRAC="${INSTALL_PATH}/dirac"
MOLCAS="${INSTALL_PATH}/molcas"
UTCHEM="${INSTALL_PATH}/utchem"

# VERSIONS
CMAKE_VERSION="3.23.2"
OPENMPI3_VERSION="3.1.0"
OPENMPI4_VERSION="4.1.2"
PYTHON2_VERSION="2.7.18"
PYTHON3_VERSION="3.9.12"

# Check whether the environment modules (http://modules.sourceforge.net/) is already installed
is_enviroment_modules_installed

check_files_and_dirs

# Install programs
setup_cmake
setup_python

if [ "$INSTALL_UTCHEM" == "YES" ] || [ "$INSTALL_DIRAC" == "YES" ]; then
	setup_openmpi
else
	echo "Skip OpenMPI installation."
fi

if [ "$INSTALL_MOLCAS" == "YES" ]; then
	setup_molcas
else
	echo "Skip Molcas installation."
fi

if [ "$INSTALL_UTCHEM" == "YES" ]; then
	setup_utchem
else
	echo "Skip utchem installation."
fi


if [ "$INSTALL_DIRAC" == "YES" ]; then
	setup_dirac
else
	echo "Skip dirac installation."
fi

echo "Build end"
wait
