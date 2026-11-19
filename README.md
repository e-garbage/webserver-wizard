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
- harden the webserver: hide version number, add security headers, block hidden files (`.git`, `.env`...), disable directory listing, drop requests for unknown hostnames / the bare IP
- optionally get free HTTPS certificates from Let's Encrypt (certbot), with HTTP → HTTPS redirect and auto-renewal
- setup UFW firewall (closes every port except 80, 443 and SSH 22, which is always kept open and rate-limited)
- harden SSH: root login disabled, password login disabled if you already have an SSH key (SFTP users from `add-sftp.sh` can still use passwords), config validated with `sshd -t` and backed up before changes
- install fail2ban to ban IPs that brute-force SSH
- update host system and enable automatic security updates
- set safe permissions on the created folder tree

> **⚠️ SSH:** if you have an SSH key, password login gets disabled. Before closing your current session, open a **new** terminal and check you can still log in.

# Tips
Site files belong to your user, with the `www-data` group. The webserver only needs to *read* them: if it could write them, a hacked webserver could change your website.
If you copy stuff from another place into the `<domaine>/html` folder, fix the permissions of the new content with

```
sudo chown -R $USER:www-data /var/www/<domaine>/html
sudo find /var/www/<domaine>/html -type d -exec chmod 755 {} +
sudo find /var/www/<domaine>/html -type f -exec chmod 644 {} +
```

Don't change the owner of `/var/www` or `/var/www/<domaine>`: they must stay owned by `root` for SFTP users to work.

# Additional scripts
## Add FTP
> ⚠️⚠️Not secured, use at your own risks⚠️⚠️

Handy script to create, edit and delete FTP user for your newly created websites. FTP users can only access the `/var/www/<domain>` folder you give them. 


## Add SFTP
the same as above but for setting up SFTP users. Secured, strongly recommanded to use on WAN accessible network


