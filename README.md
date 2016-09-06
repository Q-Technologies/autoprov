# autoprov
Perl Script to easily create new Virtual Machines within VMware (VirtualCenter)

## Background
This script was written to reduce the time people spend clicking and making decisions
 within VirtualCenter.  Now a small YAML file needs to be prepared first, then this script 
does the building.  It also paves the way for more automation as another process can prepare 
the YAML file and kick off the script.

It is a lightweight approach rather than trying to solve the whole of cloud provisioing.

## Running
Simply run:

  ```./autoprov.pl /path/to/newhost.yaml```

You will need to enter your VirtualCenter credentials.  A session file will be created so you
 will not keep having to enter your credentials everytime (timeout is 30 mins - I think this is
 a VirtualCenter setting).

* ```-v``` - some messages saying what is happening
* ```-d``` - more messages saying what is happening at a lower level


## Install
Set up Perl in your preferred way (PerlBrew or otherwise) - it has been tested on Perl 5.10.1.  
Rather than listing all the Perl modules that need to be installed here, see the 'Perl_Modules.txt'
 file.

You can install the script anywhere, but at the moment the following paths are used to load 
configuration data (this might be fixed in the future with a global config file):
* /build/config/settings.yaml - the main settings - a lot of VMware environment information
* /build/config/ip_lookup.yaml - a map to get a network name from an IP address

Update these files with your site data.  See the included samples to get you started.

### PerlBrew install

These are the steps I used to configure perlbrew for multiple users:

```bash
sudo bash 
mkdir /build # /build is really a separate filesystem
groupadd perl_users
useradd -g perl_users -m -d /build/perlbrew perlbrew
su - perlbrew
export PERLBREW_ROOT=/build/perlbrew
curl -k -L https://install.perlbrew.pl | bash
perlbrew install 5.10.1
perlbrew switch 5.10.1
chgrp -R perl_users /build/perlbrew
chmod -R g+r,g+X,g+s /build/perlbrew
cpan modules # i.e. install each of the perl modules
```

Add this to ```/etc/profile.d/perl.sh```
```bash
export PERLBREW_ROOT=/build/perlbrew
source /build/perlbrew/etc/bashrc
```

### Install VMware tools
Download the Perl SDK from VMware from https://developercenter.vmware.com/web/sdk/60/vsphere-perl.  Expand the archive on the system you want to install it on.  Then run the installer:

```bash
cd vmware-vsphere-cli-distrib
run ./ vmware-install.pl
```
When prompted with " Do you want to install precompiled Perl modules for RHEL?", say NO.  This is because they have been compiled for a very specific version of Linux.

At the end of the install, it might still complain about a couple of modules being out of date, but I found this can be ignored.

#### SOAP error fixes
There seems to be an incompatibility between the the version of HTTPS being used and the LWP perl module.  My issues were consistent with this page: 
https://kill-9.me/276/vmware-perl-sdk-hanging-login.  I applied the fixes like this:

```
rsync -av --delete vmware-vsphere-cli-distrib/lib/libwww-perl-5.805/lib/LWP \
    /build/perlbrew/perls/perl-5.10.1/lib/site_perl/5.10.1/LWP/

echo "@@ -17,9 +17,6 @@
  use HTTP::Cookies;
  use Data::Dumper;

 -# Add the lines below here
 -use LWP::Protocol::https10 ();
 -LWP::Protocol::implementor('https', 'LWP::Protocol::https10');

  ##################################################################################
  package Util;" | patch -R -p1 /build/perlbrew/perls/perl-5.10.1/lib/5.10.1/VMware/VICommon.pm
```

### Import the certs from the virtualcentre

You need to import your Virtual Center certificates for authentication to work smoothly.  Basically, you can login without trusting the certs, but the session functionality will not work.

Assuming a Red Hat like system:

```bash
curl -k -s https://vcenter/certs/download -o /tmp/cert.zip
unzip /tmp/cert.zip
mv certs/2d5c82ee.0 certs/2d5c82ee.0.crt
mv certs/2d5c82ee.r0 certs/2d5c82ee.r0.crt
sudo cp certs/*crt /etc/pki/ca-trust/source/anchors/
sudo update-ca-trust
```

