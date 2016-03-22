#!/bin/bash
set -e

# usage: ./generate.sh [versions]
#    ie: ./generate.sh
#        to update all Dockerfiles in this directory
#    or: ./generate.sh centos-7
#        to only update centos-7/Dockerfile
#    or: ./generate.sh fedora-newversion
#        to create a new folder and a Dockerfile within it

cd "$(dirname "$(readlink -f "$BASH_SOURCE")")"

versions=( "$@" )
if [ ${#versions[@]} -eq 0 ]; then
	versions=( */ )
fi
versions=( "${versions[@]%/}" )

for version in "${versions[@]}"; do
	distro="${version%-*}"
	suite="${version##*-}"
	from="${distro}:${suite}"
	installer=yum

	if [[ "$distro" == "fedora" ]]; then
		installer=dnf
	fi
	if [[ "$distro" == "photon" ]]; then
		installer=tdnf
	fi

	mkdir -p "$version"
	echo "$version -> FROM $from"
	cat > "$version/Dockerfile" <<-EOF
		#
		# THIS FILE IS AUTOGENERATED; SEE "contrib/builder/rpm/amd64/generate.sh"!
		#

		FROM $from
	EOF

	echo >> "$version/Dockerfile"

	extraBuildTags='pkcs11'
	runcBuildTags=

	case "$from" in
		oraclelinux:6)
			# We need a known version of the kernel-uek-devel headers to set CGO_CPPFLAGS, so grab the UEKR4 GA version
			# This requires using yum-config-manager from yum-utils to enable the UEKR4 yum repo
			echo "RUN yum install -y yum-utils && curl -o /etc/yum.repos.d/public-yum-ol6.repo http://yum.oracle.com/public-yum-ol6.repo && yum-config-manager -q --enable ol6_UEKR4"  >> "$version/Dockerfile"
			echo "RUN yum install -y kernel-uek-devel-4.1.12-32.el6uek"  >> "$version/Dockerfile"
			echo >> "$version/Dockerfile"
			;;
		fedora:*)
			echo "RUN ${installer} -y upgrade" >> "$version/Dockerfile"
			;;
		*) ;;
	esac

	case "$from" in
		centos:*)
			# get "Development Tools" packages dependencies
			echo 'RUN yum groupinstall -y "Development Tools"' >> "$version/Dockerfile"

			if [[ "$version" == "centos-7" ]]; then
				echo 'RUN yum -y swap -- remove systemd-container systemd-container-libs -- install systemd systemd-libs' >> "$version/Dockerfile"
			fi
			;;
		oraclelinux:*)
			# get "Development Tools" packages and dependencies
			# we also need yum-utils for yum-config-manager to pull the latest repo file
			echo 'RUN yum groupinstall -y "Development Tools"' >> "$version/Dockerfile"
			;;
		opensuse:*)
			# get rpm-build and curl packages and dependencies
			echo 'RUN zypper --non-interactive install ca-certificates* curl gzip rpm-build' >> "$version/Dockerfile"
			;;
		photon:*)
			echo "RUN ${installer} install -y wget curl ca-certificates gzip make rpm-build sed gcc linux-api-headers glibc-devel binutils libseccomp libltdl-devel elfutils" >> "$version/Dockerfile"
			;;
		*)
			echo "RUN ${installer} install -y @development-tools fedora-packager" >> "$version/Dockerfile"
			;;
	esac

	packages=(
		audit-libs-devel audit-libs-static # for "libaudit.h" and libaudit.so/libaudit.a
		btrfs-progs-devel # for "btrfs/ioctl.h" (and "version.h" if possible)
		device-mapper-devel # for "libdevmapper.h"
		glibc-static
		libseccomp-devel # for "seccomp.h" & "libseccomp.so"
		libselinux-devel # for "libselinux.so"
		libtool-ltdl-devel # for pkcs11 "ltdl.h"
		pkgconfig # for the pkg-config command
		selinux-policy
		selinux-policy-devel
		sqlite-devel # for "sqlite3.h"
		systemd-devel # for "sd-journal.h" and libraries
		tar # older versions of dev-tools do not have tar
		git # required for containerd and runc clone
		cmake # tini build
		vim-common # tini build
	)

	case "$from" in
		oraclelinux:7)
			# Enable the optional repository
			packages=( --enablerepo=ol7_optional_latest "${packages[*]}" )
			;;
	esac

	case "$from" in
		oraclelinux:6)
			# doesn't use systemd, doesn't have a devel package for it
			packages=( "${packages[@]/systemd-devel}" )
			;;
	esac

	# opensuse & oraclelinx:6 do not have the right libseccomp libs
	case "$from" in
		opensuse:*|oraclelinux:6)
			packages=( "${packages[@]/libseccomp-devel}" )
			runcBuildTags="selinux"
			;;
		*)
			extraBuildTags+=' seccomp'
			runcBuildTags="seccomp selinux"
			;;
	esac

	case "$from" in
		opensuse:*)
			packages=( "${packages[@]/btrfs-progs-devel/libbtrfs-devel}" )
			packages=( "${packages[@]/pkgconfig/pkg-config}" )
			packages=( "${packages[@]/vim-common/vim}" )
			if [[ "$from" == "opensuse:13."* ]]; then
				packages+=( systemd-rpm-macros )
			fi

			# use zypper
			echo "RUN zypper --non-interactive install ${packages[*]}" >> "$version/Dockerfile"
			;;
		photon:*)
			packages=( "${packages[@]/pkgconfig/pkg-config}" )
			echo "RUN ${installer} install -y ${packages[*]}" >> "$version/Dockerfile"
			;;
		*)
			echo "RUN ${installer} install -y ${packages[*]}" >> "$version/Dockerfile"
			;;
	esac

	echo >> "$version/Dockerfile"


	awk '$1 == "ENV" && $2 == "GO_VERSION" { print; exit }' ../../../../Dockerfile >> "$version/Dockerfile"
	echo 'RUN curl -fSL "https://golang.org/dl/go${GO_VERSION}.linux-amd64.tar.gz" | tar xzC /usr/local' >> "$version/Dockerfile"
	echo 'ENV PATH $PATH:/usr/local/go/bin' >> "$version/Dockerfile"

	echo >> "$version/Dockerfile"

	echo 'ENV AUTO_GOPATH 1' >> "$version/Dockerfile"

	echo >> "$version/Dockerfile"

	# print build tags in alphabetical order
	buildTags=$( echo "selinux $extraBuildTags" | xargs -n1 | sort -n | tr '\n' ' ' | sed -e 's/[[:space:]]*$//' )

	echo "ENV DOCKER_BUILDTAGS $buildTags" >> "$version/Dockerfile"
	echo "ENV RUNC_BUILDTAGS $runcBuildTags" >> "$version/Dockerfile"
	echo >> "$version/Dockerfile"

	case "$from" in
                oraclelinux:6)
                        # We need to set the CGO_CPPFLAGS environment to use the updated UEKR4 headers with all the userns stuff.
                        # The ordering is very important and should not be changed.
                        echo 'ENV CGO_CPPFLAGS -D__EXPORTED_HEADERS__ \'  >> "$version/Dockerfile"
                        echo '                 -I/usr/src/kernels/4.1.12-32.el6uek.x86_64/arch/x86/include/generated/uapi \'  >> "$version/Dockerfile"
                        echo '                 -I/usr/src/kernels/4.1.12-32.el6uek.x86_64/arch/x86/include/uapi \'  >> "$version/Dockerfile"
                        echo '                 -I/usr/src/kernels/4.1.12-32.el6uek.x86_64/include/generated/uapi \'  >> "$version/Dockerfile"
                        echo '                 -I/usr/src/kernels/4.1.12-32.el6uek.x86_64/include/uapi \'  >> "$version/Dockerfile"
                        echo '                 -I/usr/src/kernels/4.1.12-32.el6uek.x86_64/include'  >> "$version/Dockerfile"
                        echo >> "$version/Dockerfile"
                        ;;
                *) ;;
        esac


done
