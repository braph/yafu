#!/usr/bin/env bash

# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.

unset CDPATH
set -u
set +o histexpand

USER_AGENT="Mozilla/5.0 (X11; Linux x86_64; rv:30.0) Gecko/20100101 Firefox/30.0"

URL="http://pixelbanane.de/yafu"

EMAIL=""
PASSWORD=""
COMMENT=""
HIDDEN=""
FILENAME=""
EXPIRES="max"

LOGFILE="$HOME/.yafu"

while getopts ":c:p:e:hHf:l:" OPTION; do
   case "$OPTION" in
      'c')
         COMMENT="$OPTARG"
         ;;

      'p')
         PASSWORD="$OPTARG"
         ;;

      'e')
         EMAIL="$OPTARG"
         ;;

      'H')
         HIDDEN="-F hidden=true"
         ;;

      'f')
         FILENAME="$OPTARG"
         ;;

      'l')
         LOGFILE="$OPTARG"
         ;;

      'h')
         cat << EOF
Usage: $0 [OPTIONS] FILE

OPTIONS
   -c COMMENT
   -p PASSWORD
   -e EMAIL
   -h show help
   -H Hide file in public file list
   -f FILENAME (use FILENAME instead of basename(FILE))
   -l LOGFILENAME (write uploads into logfile: $LOGFILE)
EOF
         exit 0
         ;;

      '?')
         echo "Unknown option: -$OPTARG"
         exit 1
         ;;

      ':')
         echo "Option -$OPTARG needs an argument"
         exit 1
         ;;
   esac
done

shift $(( OPTIND - 1 ))

if (( $# == 0 )) ; then
   echo "Missing file"
   exit 1
elif (( $# > 1 )) ; then
   echo "Too many arguments"
   exit 1
fi

UPLOAD_IDENTIFIER=$( wget -U "$USER_AGENT" -qO- "$URL" | sed -nr 's/.*name="UPLOAD_IDENTIFIER" value="([^"]+)".*/\1/p' )

FILE="$1"

if ! [[ "$FILENAME" ]] ; then
   FILENAME=$(basename "$FILE")
fi

OUT=$(
curl \
   -A "$USER_AGENT" \
   -# \
   -F "email=$EMAIL" \
   -F "expires=$EXPIRES" \
   -F "comment=$COMMENT" \
   -F "filename=$FILENAME" \
   -F "password=$PASSWORD" \
   -F "upload=@$FILE" \
   $HIDDEN \
   "$URL/index.php"
)

ID_AND_FILE=$(sed -nr 's!.*href="/yafu/info/([0-9]+/[^"]+).*!\1!p' <<< "$OUT")

DIRECT_LINK="$URL/$ID_AND_FILE"
INFO_LINK="$URL/info/$ID_AND_FILE"

DELETION_LINK=$(sed -nr 's!.*(http://.+/delete/[^"]+).*!\1!p' <<< "$OUT")

(
echo "Download Link: $DIRECT_LINK"
echo "Info Link: $INFO_LINK"
echo "Deletion Link: $DELETION_LINK"
) | tee -a "$LOGFILE"
