# autoprov
Perl Script to easily create new Virtual Machines within VMware (VirtualCenter)

## Background
This script was written to reduce the time people spend clicking and making decisions
 within VirtualCenter.  Now a small YAML file needs to be prepared first, then this script 
does the building.  It also paves the way for more automation as another process can prepare 
the YAML file and kick off the script.

It is a lightweight approach rather than trying to solve the whole of cloud provisioing.

## Install
Set up Perl in your preferred way (PerlBrew or otherwise) - it has been tested on Perl 5.10.1.  
Rather than listing all the Perl modules that need to be installed here, see the 'Perl_Modules.txt'
 file.

You can install the script anywhere, but at the moment the following paths are used to load 
configuration data (this might be fixed in the future with a global config file):
* /build/config/settings.yaml - the main settings - a lot of VMware environment information
* /build/config/ip_lookup.yaml - a map to get a network name from an IP address

Update these files with your site data.  See the included samples to get you started.

## Running
Simply run:

  ```./autoprov.pl /path/to/newhost.yaml```

You will need to enter your VirtualCenter credentials.  A session file will be created so you
 will not keep having to enter your credentials everytime (timeout is 30 mins - I think this is
 a VirtualCenter setting).

* ```-v``` - some messages saying what is happening
* ```-d``` - more messages saying what is happening at a lower level

