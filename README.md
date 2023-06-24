# continuation-boot

## NAME

continuation-boot - automatic kernel selection and evaluation continuation tool

## SYNOPSIS

`continuation-boot ENTRY_PATTERN [ENTRY_OFFSET] [-- COMMAND]`

## DESCRIPTION

Select the next-boot kernel based on input, and execute a command on next startup.

`ENTRY_PATTERN` is a PCRE regular expression pattern. It is matched against the human-readable name and full qualified name of the boot entries. Matched boot entries will be considered for next boot.

`ENTRY_OFFSET` is an integer. If multiple boot entries can be matched with ENTRY_PATTERN, the offset will be used to select the desired one. Count from zero. Optional.

`COMMAND` is the command to be executed. You may provide arguments for the command as well. It will run in $PWD as root user. Optional.

## BUILD

```bash
sudo wget https://netcologne.dl.sourceforge.net/project/d-apt/files/d-apt.list -O /etc/apt/sources.list.d/d-apt.list
sudo apt-get update --allow-insecure-repositories
sudo apt-get -y --allow-unauthenticated install --reinstall d-apt-keyring
sudo apt-get update
sudo apt-get install dmd-compiler dub

dub build
```
