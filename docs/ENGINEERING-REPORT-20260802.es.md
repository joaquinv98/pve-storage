# Informe de ingeniería: ZFS nativo sobre NVMe/TCP para Proxmox VE

Fecha de corte: 2026-08-02

Autoría de la serie: Joaquin Varela `<joaquinvarela@neatech.ar>`

Estado: release candidate calificado en laboratorio anidado; no certificado aún sobre hardware productivo.

## 1. Resultado ejecutivo

El backend `zfsnvme` ya funciona como un tipo de storage nativo, in-tree, en
Proxmox VE. No usa `Custom::`, `dm-multipath`, iSCSI ni estado persistente de
configfs. Conserva el modelo de lifecycle de ZFS over iSCSI —un zvol por disco,
snapshots y clones administrados en el target— y reemplaza el data-plane por
NVMe/TCP con multipath nativo del kernel.

La campaña del nuevo lab validó:

- thin provisioning y discard/UNMAP end-to-end;
- snapshot, rollback, template, linked clone y full clone;
- resize offline y rechazo seguro del resize online;
- dos caminos activos, selección de interfaz por portal y política
  `round-robin`;
- transición ANA real bajo I/O;
- aislamiento de zvols cuyo NQN no pertenece al storage;
- asignaciones concurrentes desde dos nodos sin colisión de NSID o UUID;
- migración viva ida y vuelta bajo I/O y migración a un destino degradado;
- fencing por pérdida de nodo y partición de corosync con ambos hosts vivos;
- ausencia de doble escritor, muestreada cada 200 ms;
- reconstrucción completa después de reiniciar el target;
- guard transaccional que detiene un upgrade oficial antes de que `dpkg`
  reemplace el backend, la UI o sus documentos.

La prueba de reinicio del target encontró dos fallas reales que no aparecían en
los tests funcionales normales. Ambas quedaron corregidas y el escenario se
repitió con I/O verificado hasta obtener un PASS estricto.

## 2. Arquitectura implementada

### Control-plane

Cada nodo PVE administra el pool remoto por SSH con la misma mecánica base de
`ZFSPlugin`. Las operaciones crean, destruyen, renombran, snapshottean, clonan
y redimensionan zvols. Un helper remoto Bash configura Linux `nvmet` mediante
configfs bajo un `flock` en `/run/lock/pve-nvmet.lock`.

El lock está en el target común, no en los initiators. Por eso serializa
operaciones concurrentes provenientes de cualquier nodo del cluster. La prueba
de 16 allocations paralelos produjo 15 altas inmediatas y un timeout limpio de
pmxcfs; el retry completó la operación. Los 19 volúmenes observados tuvieron 19
NSID y 19 UUID distintos, y la limpieza no dejó namespaces residuales.

### Fuente de verdad

Cada zvol administrado lleva:

- `proxmox:nvme-subsys`;
- `proxmox:nvme-nsid`;
- `proxmox:nvme-uuid`.

Configfs es estado derivado y volátil. Después de un reboot, el helper recorre
los zvols cuyo NQN coincide, valida unicidad de NSID/UUID y reconstruye los
namespaces con la misma identidad. Un zvol sin propiedades o con otro NQN no
aparece en `pvesm list` y no se publica.

### Data-plane

El initiator abre `/dev/disk/by-id/nvme-uuid.<uuid>`. El UUID estable evita
acoplar QEMU a nombres efímeros como `/dev/nvme0n5`. Cada portal se conecta con
`--host-iface`; de esta forma el path A y el path B no pueden salir
accidentalmente por management o por la misma NIC.

Linux agrupa ambos controllers en un namespace multipath nativo. La política
se aplica en sysfs. No hay daemon `multipathd`, WWID cache, `find_multipaths`,
blacklists ni remediación de SCSI paths.

### Autenticación

El secreto DH-HMAC-CHAP vive en pmxcfs con modo `0600`. No se coloca en argv:
el initiator lo consume mediante un archivo runtime y el helper del target por
stdin. El backend nunca habilita `allow_any_host`.

`nvme-host-nqns` contiene la allow-list completa de `/etc/nvme/hostnqn` para
todos los nodos autorizados. Esto no es sólo configuración de seguridad: es
necesario para reconstruir el target sin una ventana de rechazo durante un
reboot.

## 3. Cambios pedidos por la review de Proxmox

La serie se rehízo sobre los HEAD oficiales actuales y aplica las observaciones
de Max R. Carrara:

- los módulos nuevos usan `use v5.36`;
- las regex importantes son constantes `qr//nxx` y usan captures nombrados;
- los helpers internos usan alcance léxico cuando no rompe su testabilidad;
- el código nuevo usa postfix dereferencing;
- las ramas de envío no agregan entradas a `debian/changelog`.

Los tres repositorios están a cero commits detrás del upstream oficial:

| Repositorio | Upstream | Submission v2 | Ahead | Behind |
|---|---:|---:|---:|---:|
| pve-storage | `0c56bad` | `c497478` | 7 | 0 |
| pve-manager | `3e77299a` | `baa72028` | 3 | 0 |
| pve-docs | `100c85f` | `66df01f` | 5 | 0 |

Las ramas publicadas se llaman `submission/zfs-nvme-tcp-rfc-v2`. Los árboles
son idénticos a los binarios validados; la preparación final sólo completó los
mensajes y trailers `Signed-off-by` de los commits nuevos.

## 4. Hallazgos de reinicio y correcciones

### 4.1 El target consumía el cloud-init de un guest

En el primer reboot, ZFS importó bien y `nvmet_tcp` cargó, pero el hostname y
las SSH host keys cambiaron. La causa fue que cloud-init del propio target
escaneó los zvols, encontró `vm-920-cloudinit` con label `cidata` y lo tomó como
su datasource NoCloud.

Consecuencias:

- el target adoptó metadata del guest;
- regeneró host keys;
- el control-plane SSH dejó de validar;
- configfs quedó vacío hasta reparar el acceso.

Los controllers permanecieron en reconexión y el guest hizo backpressure, sin
EIO ni checksum incorrecto. Se corrigió el provisionamiento para deshabilitar
cloud-init después del bootstrap, persistir `nvmet_tcp`, fijar el hostname,
preservar la clave root correcta y guardar el cache del pool ZFS.

Este requisito también quedó documentado para instalaciones reales: un storage
server dedicado no debe continuar descubriendo datasources cloud-init dentro de
los block devices que exporta.

### 4.2 Carrera ACL-versus-port publication

Con SSH ya estable, el target reconstruyó configfs pero QEMU terminó en
`io-error`. El kernel mostró la secuencia precisa:

1. el helper creó el subsystem y enlazó los portales;
2. los initiators reconectaron inmediatamente;
3. la ACL del Host NQN todavía no existía;
4. nvmet respondió `Connect for subsystem is not allowed`;
5. el initiator trató el rechazo como permanente y eliminó ambos controllers;
6. el namespace viejo quedó sin paths y QEMU recibió seis writes fallidos.

`ctrl_loss_tmo=600` no puede proteger contra un rechazo administrativo: sólo
protege una conexión perdida/reintentable.

La corrección separa preparación y publicación:

1. crea subsystem y objetos de portal sin links públicos;
2. restaura todos los Host NQNs autorizados y sus claves DHCHAP;
3. reconstruye y valida todos los namespaces;
4. publica los links de los portales como última operación.

La allow-list completa permite que el primer nodo que actúe después del reboot
prepare también las ACL de los demás. Así ningún controller preexistente puede
alcanzar un target parcialmente reconstruido.

El filesystem del guest afectado se preservó con snapshot, se reparó offline
con `e2fsck -fy`, y una segunda pasada `-fn` quedó limpia. No se ocultó este
fallo: forma parte del registro de calificación.

### 4.3 Repetición final

Con el fix desplegado:

- ciclo ping down/up del target: 18,3 s;
- 6 namespaces, 2 Host ACLs y 2 portales reconstruidos;
- controllers originales reconectados en el intento 4/300;
- cero `Connect not allowed`;
- cero controller removals;
- cero block I/O failures;
- QEMU permaneció `running`;
- el loop del guest avanzó de 8 a 82 iteraciones;
- resultado final `PASS`, SHA-256 correcto.

## 5. Performance y resiliencia de caminos

Para demostrar uso simultáneo de ambos paths se limitaron las interfaces del
target a 100 Mbit/s cada una. Con fio directo:

| Escenario | MB/s | IOPS |
|---|---:|---:|
| Path A a 100 Mbit/s | 11,94 | 83,53 |
| Path B a 100 Mbit/s | 11,99 | 83,98 |
| Multipath 2 x 100 Mbit/s | 23,87 | 174,25 |
| Multipath sin shaping | 91,47 | 691,23 |

El throughput dual fue 1,999 veces el path A. Es evidencia funcional de striping
por ambos controllers; no debe usarse como sizing de una cabina física.

Fault injection completado:

- corte A durante 12 s: fio `error=0`;
- corte B durante 12 s: fio `error=0`;
- corte A+B durante 15 s con política queue: reanudación y checksum válidos;
- corte largo A+B con fast-fail: EIO esperado, recuperación a 2 paths y
  checksum post-recovery válido;
- ANA `optimized -> non-optimized -> optimized` bajo 370.259 I/O, sin short IO;
- migración hacia un nodo con sólo un path activo, seguida de restauración.

## 6. Migración y HA

Migraciones vivas del VMID 920 con escrituras y SHA continuos:

| Dirección/condición | Downtime | Total | Estado transferido |
|---|---:|---:|---:|
| node1 -> node2 | 69 ms | 7,775 s | 412,9 MiB |
| node2 -> node1 | 124 ms | 8,375 s | 417,8 MiB |
| node1 -> node2, destino single-path | 645 ms | 9,645 s | 446,0 MiB |

En la pérdida dura del nodo que alojaba la VM, el survivor conservó quorum por
QDevice. QEMU reinició aproximadamente a los 143 s y el guest respondió a los
151 s. No hubo start antes del fencing acknowledgement.

En la partición de corosync, ambos hosts físicos/anidados siguieron encendidos y
el nodo aislado conservó sus paths NVMe. Perdió quorum, siguió siendo el único
writer hasta que su watchdog se auto-fenceó cerca de los 59 s, y el survivor
sólo inició la VM después de liberar el lock. El muestreo de QEMU a 200 ms dio:

- último writer origen: `1785632199.89102`;
- primer writer survivor: `1785632291.04184`;
- gap sin writer: `91.1508226` s;
- overlap/doble escritor: `false`.

## 7. Upgrades

Los paquetes de laboratorio se construyeron con las versiones oficiales para
probar exactamente el código actual. APT detecta que el artefacto del repositorio
tiene el mismo version string pero otro contenido e intenta reinstalarlo. Sin
protección, un `full-upgrade` borraría el backend local aunque no hubiera un
cambio de API.

La solución temporal no es congelar indefinidamente paquetes core. Se instaló
un hook `DPkg::Pre-Install-Pkgs` que inspecciona cada `.deb` antes de que dpkg
escriba. Exige:

- registro y módulo backend;
- `nvme-host-nqns`;
- publish-after-ACL;
- UI correspondiente;
- documentación operativa.

La prueba aceptó los tres artefactos custom y rechazó los tres oficiales. Un
`apt-get -y full-upgrade` real terminó con rc 100 antes de dpkg; los hashes de
backend y UI quedaron idénticos y el storage siguió activo.

Como cierre del lab se ejecutó además un soak continuo de 741 segundos dentro
del guest: 681 ciclos de 64 MiB, equivalentes a 45.701.136.384 bytes escritos y
verificados. Terminó `PASS`, SHA-256 correcto, sin nuevos errores de bloque o
ext4, QEMU `running` y ambos paths `live`.

Esto evita una rotura silenciosa, pero no convierte un fork en mantenible para
siempre. Antes de cada upgrade, mientras la serie no esté upstream, hay que
rebasar sobre las versiones candidatas, compilar, ejecutar la batería y ofrecer
los paquetes compatibles en la misma transacción. La resolución durable es el
merge oficial.

## 8. Veredicto y límite de la afirmación “production-ready”

El código está funcionalmente en nivel release candidate de laboratorio. Las
fallas de integridad más importantes —foreign ownership, concurrencia de NSID,
ANA, pérdida de paths, target reboot, migración, fencing y doble escritor— ya
tienen evidencia positiva y artefactos crudos.

No corresponde llamarlo “certificado enterprise” todavía porque falta validar
la plataforma donde se desplegará:

1. soak mixto de 72 h o más sobre hardware real;
2. p50/p95/p99/p99.9 y RTO con carga representativa;
3. fallas físicas de NIC, cable, switch, VLAN y portal;
4. pool casi lleno y completamente lleno;
5. backup y restore completos con RPO/RTO medido;
6. rolling upgrade con los paquetes candidatos exactos;
7. decisión explícita entre TLS NVMe/TCP o redes físicamente aisladas;
8. review y aceptación upstream.

Los datos estructurados están en `docs/validation-results.json` y los logs
crudos del lab en `lab/new-lab/results-20260802/raw/`.

Al cerrar la campaña se eliminaron por las APIs normales el template, ambos
clones, el volumen de resize y el snapshot de rescate. El estado entregado
conserva únicamente VMID 920, dos namespaces (disco y cloud-init), dos paths por
nodo, pool `ONLINE`, QDevice activo y fencing armado.
