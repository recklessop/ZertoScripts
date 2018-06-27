$pass = read-host -assecurestring -Prompt 'Enter ZVM password' | convertfrom-securestring
$pass | out-file "c:\passwd.txt"
