```
                   .      ██╗    ██╗███████╗██████╗ ███████╗███████╗██████╗ ██╗   ██╗███████╗██████╗ 
         /^\     .        ██║    ██║██╔════╝██╔══██╗██╔════╝██╔════╝██╔══██╗██║   ██║██╔════╝██╔══██╗
    /\   "V"              ██║ █╗ ██║█████╗  ██████╔╝███████╗█████╗  ██████╔╝██║   ██║█████╗  ██████╔╝
   /__\   I      O  o     ██║███╗██║██╔══╝  ██╔══██╗╚════██║██╔══╝  ██╔══██╗╚██╗ ██╔╝██╔══╝  ██╔══██╗
  //..\\  I     .         ╚███╔███╔╝███████╗██████╔╝███████║███████╗██║  ██║ ╚████╔╝ ███████╗██║  ██║    
  \].`[/  I                ╚══╝╚══╝ ╚══════╝╚═════╝ ╚══════╝╚══════╝╚═╝  ╚═╝  ╚═══╝  ╚══════╝╚═╝  ╚═╝
  /l\/j\  (]    .  O.    ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░█░█░▀█▀░▀▀█░█▀█░█▀▄░█▀▄      
 /. ~~ ,\/I          .   ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░█▄█░░█░░▄▀░░█▀█░█▀▄░█░█    
 \\L__j^\/I       o.     ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░▀░▀░▀▀▀░▀▀▀░▀░▀░▀░▀░▀▀░
  \/--v}  I     o   .    ░░by e-garbage░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░   
  |    |  I   _________. ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░
  |    |  I c(`       ')o░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░lazy script for lazy people░░
  |    l  I   \.     ,/  ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░
_/j  L l\_!  _//^---^\\_ ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░ 


```


# Set up your webserver in one script with Webserver Wizard

I was tired of doing the same exact config everytime I have to spin up a webserver.
I usally do this for simple static website without much back-end, but still I can mess the things up pretty quickly


> **⚠️ Note:** These scripts have been tested and are intended for **Ubuntu Server 24.04 LTS**. Compatibility with other Ubuntu versions or Linux distributions is not guaranteed. Use at your own risk on other systems.


# Quick oneliner auto setup
Copy paste this line in the terminal of your webserver

```
bash <(curl -fsSL https://raw.githubusercontent.com/e-garbage/webserver-wizard/main/wizard.sh)

```

# What it does
- Install Nginx or Apache2
- setup as many domaine as you want under `/var/www/<domaine>/html`
- setup UFW port config (by default it will close every ports and keep 80 and 443 open)
- setup ssh with a default config 
- update host system
- check permissions of created folder tree

# Tips
If you copy stuff from another place into the `<domaine>/html` folder, dont forget to fix the permission of the new content with

```
sudo chown -R www-data:www-data .
```
# Additional scripts
## Add FTP

Handy script to create, edit and delete FTP user for your newly created websites. FTP users can only access the `/var/www/<domain>` folder you give them. 
Not secured, use at your own risks.

## Add SFTP
the same as above but for setting up SFTP users. Secured, strongly recommanded to use on WAN accessible network


