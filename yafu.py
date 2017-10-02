#!/usr/bin/python3

# yafu - command line client for YaFU
# Copyright (C) 2016 Benjamin Abendroth
# 
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
# 
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
# 
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.

import argparse, requests, re, pickle
from time import time
from datetime import datetime, timedelta
from os.path import expanduser, isfile, basename, devnull
from urllib.parse import urlencode
from string import Template

DEFAULT_FORMAT = '''=== $basename $expired_str===
File: $file
Date: $date
Expires: $expire_date [$expires]
Type: $type
URL: $direct_url
Info: $info_url
Delete: $deletion_url
'''

RECORD_SHORTCUTS = {
   'b': 'basename',     'f': 'file',            'h': 'hidden',
   'i': 'info_url',     'd': 'deletion_url',    'u': 'direct_url',
   'D': 'date',         'e': 'expire_date',     'x': 'expired',
   'E': 'expires'
}

parser = argparse.ArgumentParser(prog='YaFU', description='Commandline client for YaFU')

# FILE OPTIONS
fileopts = parser.add_argument_group(title='File Options')
fileopts.add_argument('--db',    help='Database file', type=expanduser)
fileopts.add_argument('--no-db', help='Disable database', dest='db', action='store_const', const=devnull)

# ACTIONS
actions = parser.add_argument_group(title='Actions')
actions = actions.add_mutually_exclusive_group(required=True)
actions.add_argument('-d', '--delete',  help='Delete the given links', metavar='URL', nargs='+')
actions.add_argument('-u', '--upload',  help='Files to upload', metavar='FILE', nargs='+')
actions.add_argument('-l', '--list',    help='List the records in database', action='store_true')

# UPLOAD ACTION
ulcmd = parser.add_argument_group('Upload Options')
ulcmd.add_argument('-b', '--base-url',  help='Specify base-url')
ulcmd.add_argument('-e', '--email',     help='Specify email for file upload')
ulcmd.add_argument('-p', '--password',  help='Specify password for file upload')
ulcmd.add_argument('-c', '--comment',   help='Specify comment for file upload')
ulcmd.add_argument('-x', '--expires',   help='Specify expire time',
   choices=['30m', '1h', '6h', '1d', '3d', '1w', 'max'])

hide_group = ulcmd.add_mutually_exclusive_group()
hide_group.add_argument('--private', help='Hide file in public list [DEFAULT]', dest='hide', action='store_true')
hide_group.add_argument('--public',  help='Show file in public list', dest='hide', action='store_false')

# LIST ACTION
listcmd = parser.add_argument_group('List Options')
listcmd.add_argument('--show-expired',   help='List also expired records', action='store_true')
listcmd.add_argument('--date-format',    help='Specify date format')
listcmd.add_argument('-n', '--number',   help='Only list the last N records', type=int)
listcmd.add_argument('-f', '--format',   help='Specify output format', type=Template)

parser.set_defaults(
   db =           '~/.config/yafu.db', 
   base_url =     'http://pixelbanane.de/yafu',
   format =       DEFAULT_FORMAT,
   date_format =  '%Y-%m-%d %H:%M:%S',
   hide =         True,
   expires =      '1w'
)

class RecordExpander(dict):

   def __init__(self, record, args):
      self._record = record
      self._cache = {}
      self._args = args

   def __getitem__(self, var):

      if len(var) == 1:
         try:
            var = RECORD_SHORTCUTS[var]
         except:
            raise Exception('Record shortcut not found: ' + var)

      if var in self._record:
         return self._record[var]

      if var not in self._cache:
         self._cache[var] = self.getVar(var)

      return self._cache[var]

   def getVar(self, var):

      if var == 'expired':
         return (self._record['expires'] != 'max' and
                 time() > self._record['expire_ts'])

      if var == 'expired_str':
         return 'EXPIRED ' if self['expired'] else ''

      if var == 'type':
         return 'Private' if self._record['hide'] else 'Public'

      if var == 'date':
         return datetime.fromtimestamp(self._record['date_ts']).strftime(self._args.date_format)

      if var == 'expire_date':
         if self._record['expire_ts'] == 0:
            return 'NEVER'

         return datetime.fromtimestamp(self._record['expire_ts']).strftime(self._args.date_format)
         
      if var == 'direct_url':
         return '%s/%s/%s' % (
                 self['base_url'], self['id'], self['basename_escaped'] )

      if var == 'info_url':
         return '%s/info/%s/%s' % (
                 self['base_url'], self['id'], self['basename_escaped'] )

      if var == 'deletion_url':
         return '%s/delete/%s' % (self['base_url'], self['delete_id'])

      if var == 'basename':
         return basename(self._record['file'])

      if var == 'basename_escaped':
         return urlencode({'': self['basename']})[1:]

      raise KeyError


def yafu_list(db, args):

   offset = args.number - len(db) if args.number else 0

   for record in db:
      offset += 1
      if offset < 0:
         continue

      record = RecordExpander(record, args)

      if args.show_expired or not record['expired']:
         print(args.format.safe_substitute(record))


def yafu_delete(url):

   params = { 'confirm': 'do it!' }
   response = requests.post(url, data=params)

def yafu_upload(file, args):

   ul_files = { 'upload': open(file, 'rb').read() }
   # https://stackoverflow.com/questions/33717690/python-requests-post-with-unicode-filenames

   ul_parameters = {
      'filename':    basename(file),
      'expires':     args.expires,
      'email':       args.email,
      'password':    args.password,
      'comment':     args.comment
   }

   if args.hide:
      ul_parameters['hide'] = 'true'

   response = requests.post(args.base_url + '/index.php', files=ul_files, data=ul_parameters)

   try:
      match = re.search('href="[^"]*/info/([0-9]+)/[^"]+', response.text)
      ul_id = match.group(1)
   except:
      ul_id = 'NOT_AVAILABLE'
      print('Could not extract file id')

   try:
      match = re.search('http://.+/delete/([^"]+)', response.text)
      delete_id = match.group(1)
   except:
      delete_id = 'NOT_AVAILABLE'
      print('Could not extract delete id')

   record = {
      'file':        file,
      'base_url':    args.base_url,
      'id':          ul_id,
      'delete_id':   delete_id,
      'expires':     args.expires,
      'email':       args.email,
      'date_ts':     int( time() ),
      'hide':        args.hide,
      'expire_ts':   0
   }

   if record['expires'] != 'max':
      n = int(record['expires'][:-1])
      t = { 'm':'minutes', 'h':'hours', 'd':'days', 'w':'weeks' }[ record['expires'][-1] ]

      td = timedelta(**{t:n})

      record['expire_ts'] = int( ( datetime.now() + td ).timestamp() )

   return record

args = parser.parse_args()

try:
   record_storage = pickle.load(open(args.db, 'rb'))
except:   
   record_storage = []

if args.upload:
   for file in args.upload:
      record = yafu_upload(file, args)

      fmt_record = RecordExpander(record, args)
      print(args.format.safe_substitute(fmt_record))

      record_storage.append(record)

elif args.delete:
   for url in args.delete:
      yafu_delete(url)

elif args.list:
   yafu_list(record_storage, args) 

pickle.dump(record_storage, open(args.db, 'wb'))
