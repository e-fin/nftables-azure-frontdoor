# nftables-azure-frontdoor
Script and Config to pull Azure Front Door backend IP ranges, and only permit Azure Front Door to access your webserver on port 80 and 443

I made this because adding the list of IP ranges manually to whatever VPS service firewall can be a pain in the butt, especially when they need updating. This can be ran manually whenever you need it, or put in a cron job

```
sudo mkdir -p /var/lib/afd-ranges
sudo nft -f /etc/nftables.conf
sudo bash update-afd-set.sh
```
