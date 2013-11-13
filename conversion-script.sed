s/\x85/.../g
s/\x92/''/g
s/\\'/''/g
s/','/',E'/g
s/\x96/\\-/g
s/\(\x93\|\x94\)/\\"/g
s/int([0-9]*)/int/g
s/unsigned//g
s/datetime/timestamp with time zone/g
/^  KEY .*$/d
s/\(PRIMARY.*\),$/\1/
s/),(/),\n(/g
/^USE.*;$/d
/^\/\*.*\*\/;$/d
