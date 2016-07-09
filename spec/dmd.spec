Name:		dmd
Version:	2.071.0
Release:	1%{?dist}
Summary:	D Compiler
Group:          System Environment/Network
License:        GPLv3
URL:     	http://dlang.org/
Source0:        dmd.2.071.0.linux.tar.xz
BuildRoot:      %{_tmppath}/%{name}-%{version}-%{release}-root-%(%{__id_u} -n)

Source1:        dmd.conf
Source2:	dmd.bash_completion
Source3:	copyright

Provides:	dmd
Requires:	libgcc


%define debug_package %{nil}

%description
D is a systems programming language with C-like syntax and static typing. It combines efficiency, control and modeling power with safety and programmer productivity.

%prep

%setup -n dmd2
# This creates a directory %{_builddir}/dmd2/
# When the tar file is extracted, this is what it's name is

%build
# nothing to build with this

%install
# Make the destination directories
%{__mkdir_p} %{buildroot}/etc/bash_completion.d/
%{__mkdir_p} %{buildroot}/usr/bin/
%{__mkdir_p} %{buildroot}/usr/include/dmd/druntime/import/
%{__mkdir_p} %{buildroot}/usr/include/dmd/phobos/
%{__mkdir_p} %{buildroot}/usr/lib/
%{__mkdir_p} %{buildroot}/usr/lib64/
%{__mkdir_p} %{buildroot}/usr/share/dmd/html/
%{__mkdir_p} %{buildroot}/usr/share/dmd/samples/
%{__mkdir_p} %{buildroot}/usr/share/doc/dmd/
%{__mkdir_p} %{buildroot}/usr/share/man/

# Copy over the files
cd %{_builddir}/dmd2/
cp %SOURCE1 %{buildroot}/etc/dmd.conf
cp %SOURCE2 %{buildroot}/etc/bash_completion.d/dmd
cp ./linux/bin64/ddemangle %{buildroot}/usr/bin/
cp ./linux/bin64/dman %{buildroot}/usr/bin/
cp ./linux/bin64/dmd %{buildroot}/usr/bin/
cp ./linux/bin64/dumpobj %{buildroot}/usr/bin/
cp ./linux/bin64/dustmite %{buildroot}/usr/bin/
cp ./linux/bin64/obj2asm %{buildroot}/usr/bin/
cp ./linux/bin64/rdmd %{buildroot}/usr/bin/
cp -af ./src/druntime/import/* %{buildroot}/usr/include/dmd/druntime/import/
cp -af ./src/phobos/* %{buildroot}/usr/include/dmd/phobos/
#cp -af ./linux/lib32/* %{buildroot}/usr/lib/
cp -af ./linux/lib64/* %{buildroot}/usr/lib64/
cp -af ./html/* %{buildroot}/usr/share/dmd/html/
cp -af ./samples/* %{buildroot}/usr/share/dmd/samples/
cp %SOURCE3 %{buildroot}/usr/share/doc/dmd/copyright
cp -af ./man/* %{buildroot}/usr/share/man/

%clean

%files
%defattr(0444,root,root,0755)

# Configuration

/etc/dmd.conf
/etc/bash_completion.d/dmd

# Binaries

%attr(0555,root,root) /usr/bin/ddemangle
%attr(0555,root,root) /usr/bin/dman
%attr(0555,root,root) /usr/bin/dmd
%attr(0555,root,root) /usr/bin/dumpobj
%attr(0555,root,root) /usr/bin/dustmite
%attr(0555,root,root) /usr/bin/obj2asm
%attr(0555,root,root) /usr/bin/rdmd

# Library Files

#/usr/lib/libphobos2.a
#/usr/lib/libphobos2.so
#/usr/lib/libphobos2.so.0.71
#/usr/lib/libphobos2.so.0.71.0
/usr/lib64/libphobos2.a
/usr/lib64/libphobos2.so
/usr/lib64/libphobos2.so.0.71
/usr/lib64/libphobos2.so.0.71.0

# Include Files

/usr/include/dmd/

# Documentation

/usr/share/dmd/
/usr/share/doc/dmd/copyright
/usr/share/man/man1/dmd.1.gz
/usr/share/man/man1/dumpobj.1.gz
/usr/share/man/man1/obj2asm.1.gz
/usr/share/man/man1/rdmd.1.gz
/usr/share/man/man5/dmd.conf.5.gz

%changelog
