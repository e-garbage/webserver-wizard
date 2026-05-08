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

# Quick oneliner auto setup
Copy paste this line in the terminal of your webserver

```
bash <(curl -fsSL https://raw.githubusercontent.com/e-garbage/webserver-wizard/main/wizard.sh)

```

# What it does
- Install Nginx or Apache2
- setup as many domaine as you want under `/var/www/<domaine>/``
- setup UFW port config (by default it will close every ports and keep 80 and 443 open)
- update host system