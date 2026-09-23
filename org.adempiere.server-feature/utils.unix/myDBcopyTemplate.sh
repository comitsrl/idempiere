#!/bin/sh

# Copy Database after backup
# $Id: myDBcopyTemplate.sh,v 1.1 2002/10/07 01:23:32 jjanke Exp $

DATE=$(date +%Y%m%d_%H%M%S)
mv "$IDEMPIERE_HOME"/data/ExpDat.tar.7z "$IDEMPIERE_HOME"/data/ExpDat"$DATE".tar.7z
echo copy "$IDEMPIERE_HOME"/data/ExpDat"$DATE".tar.7z to backup media
