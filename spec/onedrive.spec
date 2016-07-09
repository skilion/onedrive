Name:		onedrive
Version:	1.1
Release:	1%{?dist}
Summary:	Microsoft OneDrive Client
Group:          System Environment/Network
License:        GPLv3
URL:     	https://github.com/skilion/onedrive
Source0:        README.md
BuildRoot:      %{_tmppath}/%{name}-%{version}-%{release}-root-%(%{__id_u} -n)

BuildRequires:	git
BuildRequires:	dmd
BuildRequires:	sqlite-devel >= 3.7.15
BuildRequires:	libcurl-devel

Requires:	sqlite >= 3.7.15
Requires:	libcurl 

%define debug_package %{nil}

%description
Microsoft OneDrive Client for Linux

%prep

%setup -c -D -T
# This creates cd %{_builddir}/%{name}-%{version}/
# clone the repository
git clone https://github.com/skilion/onedrive.git

# We should now have %{_builddir}/%{name}-%{version}/onedrive/

# Patch the makefile so it can find the dmd include directories
# Patch the makefile so we install to the right location & remove the systemd service item
cd %{_builddir}/%{name}-%{version}/onedrive/

%build
cd %{_builddir}/%{name}-%{version}/onedrive/
make

%install
# Make the destination directories
%{__mkdir_p} %{buildroot}/etc/
%{__mkdir_p} %{buildroot}/usr/bin/
cp %{_builddir}/%{name}-%{version}/onedrive/onedrive.conf %{buildroot}/etc/onedrive.conf
cp %{_builddir}/%{name}-%{version}/onedrive/onedrive %{buildroot}/usr/bin/onedrive

%clean

%files
%defattr(0444,root,root,0755)
/etc/onedrive.conf
%attr(0555,root,root) /usr/bin/onedrive

%post
mkdir -p /root/.config/onedrive
mkdir -p /root/OneDrive


%changelog
