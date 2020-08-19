#!/bin/sh

init_dirs()
{
	export TMPDIR=$(mktemp -d)
	export FAUCET_CONFIG=$TMPDIR/etc/faucet/faucet.yaml
	export GAUGE_CONFIG=$TMPDIR/etc/faucet/gauge.yaml
	if [ ! -d "$TMPDIR" ] ; then
		exit 1
	fi
	mkdir -p $TMPDIR/etc/faucet
	MIRROR_PCAP=$TMPDIR/mirror.cap
}

clean_dirs()
{
	docker rm -f testcon || exit 1
	docker network rm testnet || exit 1
	FAUCET_PREFIX=$TMPDIR docker-compose -f docker-compose.yml -f docker-compose-standalone.yml stop
	rm -rf $TMPDIR
}

conf_faucet()
{
	echo configuring faucet
	sudo rm -f $FAUCET_CONFIG
cat >$FAUCET_CONFIG <<EOFC || exit 1
acls:
  allowall:
  - rule:
      actions:
        allow: 1
  denyall:
  - rule:
      actions:
        allow: 0
dps:
  # Need at least DP defined always.
  anchor:
    dp_id: 0x99
    hardware: Open vSwitch
    interfaces:
        1:
           native_vlan: 100
  testnet:
    dp_id: 0x1
    hardware: Open vSwitch
    interfaces:
        0xfffffffe:
            native_vlan: 100
            opstatus_reconf: false
    interface_ranges:
        1-10:
            native_vlan: 100
            acls_in: [denyall]
EOFC
}

conf_gauge()
{
	echo configuring gauge
cat >$GAUGE_CONFIG <<EOGC || exit 1
faucet_configs:
    - '/etc/faucet/faucet.yaml'
watchers:
    port_status_poller:
        type: 'port_state'
        all_dps: True
        db: 'prometheus'
    port_stats_poller:
        type: 'port_stats'
        all_dps: True
        interval: 30
        db: 'prometheus'
dbs:
    prometheus:
        type: 'prometheus'
        prometheus_addr: '0.0.0.0'
        prometheus_port: 9303
EOGC
}

conf_keys ()
{
	echo creating keys
	mkdir -p /opt/faucetconfrpc || exit 1
	FAUCET_PREFIX=$TMPDIR docker-compose -f docker-compose.yml -f docker-compose-standalone.yml up faucet_certstrap || exit 1
	ls -al /opt/faucetconfrpc/faucetconfrpc.key || exit 1
}

wait_faucet ()
{
	for p in 6653 6654 ; do
		PORTCOUNT=""
		while [ "$PORTCOUNT" = "0" ] ; do
			echo waiting for $p
			PORTCOUNT=$(ss -tHl sport = :$p|grep -c $p)
			sleep 1
		done
	done
}

wait_acl ()
{
	echo waiting for ACL to be applied
	DOVESNAPID="$(docker ps -q --filter name=dovesnap_plugin)"
	ACLCOUNT=0
	while [ "$ACLCOUNT" != "2" ] ; do
		docker logs $DOVESNAPID
		sudo cat $FAUCET_CONFIG
		ACLCOUNT=$(sudo grep -c allowall $FAUCET_CONFIG)
		sleep 1
	done
}

wait_mirror ()
{
	echo waiting for mirror to be applied
	DOVESNAPID="$(docker ps -q --filter name=dovesnap_plugin)"
	MIRRORCOUNT=0
	while [ "$MIRRORCOUNT" != "1" ] ; do
		docker logs $DOVESNAPID
		sudo cat $FAUCET_CONFIG
		MIRRORCOUNT=$(sudo grep -c mirror: $FAUCET_CONFIG)
		sleep 1
	done
}

init_ovs ()
{
	docker-compose -f docker-compose.yml up -d ovs || exit 1
	OVSID="$(docker ps -q --filter name=ovs)"
	while ! docker exec -t $OVSID ovs-vsctl show ; do
		echo waiting for OVS
		sleep 1
	done
	docker exec -t $OVSID /bin/sh -c 'for i in `ovs-vsctl list-br` ; do ovs-vsctl del-br $i ; done' || exit 1
}