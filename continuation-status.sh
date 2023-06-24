#!/usr/bin/env bash

sudo systemctl status continuation-boot.service
sudo journalctl -b -u continuation-boot.service