# Informe de ingeniería: ZFS sobre NVMe/TCP nativo para Proxmox VE

Fecha de corte: 2026-07-15  
Estado: candidato de release validado en laboratorio; pendiente de calificación sobre el hardware de producción  
Branch: `feature/zfs-nvme-tcp`

## 1. Resumen ejecutivo

Se implementó un nuevo tipo de storage nativo de Proxmox VE, `zfsnvme`, dentro
de `pve-storage`. Conserva el modelo operativo de ZFS over iSCSI —ZFS remoto
administra el ciclo de vida de zvols y Proxmox consume dispositivos de bloque
compartidos—, pero reemplaza LIO/iSCSI y `dm-multipath` por NVMe/TCP, `nvmet` y
el multipath ANA nativo del kernel Linux.

El trabajo no quedó como `PVE::Storage::Custom::*`: incluye el registro en el
core, el backend de lifecycle, un proveedor target `NVMET`, tests dentro del
harness oficial, UI en `pve-manager`, documentación en `pve-docs`, paquetes
Debian versionados y un guard transaccional para upgrades. Los forks son
espejos públicos de revisión; la vía canónica para upstream sigue siendo una
serie de patches a `pve-devel`.

La validación del lab cubrió lifecycle ZFS, thin/discard, snapshots, rollback,
templates, linked clones, resize offline, migración en vivo, pérdida de paths,
pérdida simultánea de los dos paths, reconstrucción de configfs, caída del
control-plane SSH, deactivación segura y failover HA con fencing real. El build
final ejecutó 590 assertions automatizadas además de las pruebas integradas en
el clúster.

El resultado es apto como candidato para una calificación enterprise. No sería
honesto llamarlo “certificado para producción” solamente con virtualización
anidada: faltan el soak prolongado y las pruebas sobre las NIC, switches,
firmware, kernel y carga reales del sitio destino.

## 2. Alcance implementado

El backend soporta:

- alta y baja de zvols thin;
- publicación de cada zvol como namespace NVMe;
- activación del storage y del volumen por UUID estable;
- snapshots y rollback;
- templates y linked clones;
- eliminación de clones y volúmenes;
- discard/TRIM end-to-end;
- resize offline;
- status y listado de volúmenes;
- storage compartido y migración en vivo;
- multipath nativo con una conexión por portal/interfaz;
- autenticación DH-HMAC-CHAP por Host NQN;
- reconciliación declarativa del target desde propiedades ZFS.

El resize online se rechaza antes de modificar ZFS. QEMU abre este backend como
`host_device` y el camino actual de Proxmox intenta `block_resize`, operación
que no resuelve el cambio de tamaño de ese host block device. La secuencia
soportada es detener, redimensionar y volver a iniciar la VM.

## 3. Cambios de código

### 3.1 `pve-storage`

Se agregó `PVE::Storage::ZFSNVMePlugin` y se lo registró en
`PVE::Storage.pm`. También se hizo overridable el despacho del proveedor LUN
del padre ZFS, un cambio pequeño necesario para reutilizar el lifecycle maduro
de `ZFSPlugin` sin duplicarlo.

El plugin define el schema `zfsnvme` y sus propiedades:

- NQN del subsystem;
- lista de portales NVMe/TCP;
- lista posicional de interfaces locales;
- política de I/O multipath;
- keep-alive, reconnect y controller-loss timeouts;
- cantidad opcional de I/O queues;
- identidad y secreto DH-HMAC-CHAP.

El proveedor `PVE::Storage::LunCmd::NVMET` contiene un helper remoto estricto
para configfs. Las mutaciones se serializan con `flock` sobre
`/run/lock/pve-nvmet.lock`, validan todos los valores antes de escribir y son
idempotentes. `reconcile()` deriva el target deseado del inventario ZFS y puede
reconstruirlo aunque se pierda el estado efímero de configfs.

### 3.2 Identidad durable

La fuente de verdad no es configfs. Cada zvol propio conserva, entre otras, las
propiedades:

- `proxmox:nvme-subsys`;
- `proxmox:nvme-nsid`;
- `proxmox:nvme-uuid`.

El path entregado a QEMU es `/dev/disk/by-id/nvme-uuid.<uuid>`. No depende de
si el kernel enumeró el controlador como `nvme0`, `nvme1` ni de qué nodo hizo
la activación. Antes de adoptar o modificar un zvol se comprueban ownership,
NQN, NSID, UUID, modelo y serial determinístico. Un zvol ajeno o ambiguo se
rechaza sin mutación.

### 3.3 Dataplane multipath

Los dos controllers del mismo NQN forman un único namespace multipath nativo.
El plugin exige `nvme_core.multipath=Y`, verifica controllers vivos desde
sysfs, configura la `iopolicy` y conecta cada portal con su `--host-iface`.

Si un controller existe por la interfaz equivocada, se reemplaza de a un path.
El storage no se baja para corregir esa desviación. Como hardening final, cada
nodo verifica primero que todas las interfaces configuradas existan; una
enumeración distinta falla en preflight antes de reconciliar el target.

### 3.4 Autenticación y secretos

Cada nodo tiene un Host NQN único y una ACL propia en el target.
`allow_any_host` permanece deshabilitado. La clave DH-HMAC-CHAP se guarda en
pmxcfs con modo `0600`, llega a `nvme-cli` mediante un JSON temporal protegido
y se escribe en el target por stdin. No aparece como argumento del proceso.

DH-HMAC-CHAP autentica pero no cifra los bloques. Esta serie todavía no
configura TLS 1.3/PSK de NVMe/TCP; por eso la baseline exige redes físicamente
aisladas o protección criptográfica equivalente. Agregar TLS merece una serie
separada: debe resolver keyrings, distribución y rotación de PSK, compatibilidad
de `nvme-cli`/kernel y rollback seguro.

### 3.5 Control-plane

Las operaciones ZFS y de target viajan por el canal SSH del backend ZFS. El
I/O de una VM ya conectada no depende de ese canal: usa directamente las dos
redes NVMe/TCP. Sí dependen de SSH el capacity status, allocate, free,
snapshot, clone, resize y reconcile.

En producción, `server` debe resolver a una IP de management redundante o a un
DNS/VIP administrado por el storage. No se agregó una cache de capacidad que
simule salud durante una caída: reportar el control-plane inactivo es más
seguro que exponer datos viejos mientras fallan mutaciones.

### 3.6 Deactivación y eliminación seguras

Se trazaron los callers de Proxmox: migración, backup y HA activan storage y
volumen, pero no llaman `deactivate_storage` como parte normal del movimiento
de una VM. `activate_volume` fuerza reconcile y espera el by-id UUID antes de
devolver control, de modo que QEMU en el destino no abre un namespace todavía
incompleto.

Aun así, se endureció la baja en dos niveles:

1. `deactivate_storage` escanea los namespace heads del subsystem, los file
   descriptors de procesos y los holders del kernel; si QEMU u otro consumidor
   usa el dispositivo, no ejecuta `nvme disconnect`.
2. `on_delete_hook` exige que el dataset ZFS propio esté vacío. Es una defensa
   cluster-wide: evita borrar la configuración desde un nodo ocioso mientras
   otro nodo todavía posee discos de ese storage.

El error ya no se ignora. Una baja insegura falla cerrada y deja sesiones,
secreto y configuración intactos.

### 3.7 UI y documentación

`pve-manager` incorpora el editor nativo del tipo `zfsnvme`, con los campos y
validaciones correspondientes. `pve-docs` integra el backend al manual y deja
explícitos topología, autenticación, multipath, limitaciones, preflight,
control-plane y procedimiento de remoción.

## 4. Estrategia de upgrades

La solución durable es upstream. Mientras los paquetes oficiales no incluyan
los tres componentes, una actualización podría reemplazar backend o UI aunque
la API Perl siga cargando.

No se usó un hold permanente. Mantener indefinidamente un
`libpve-storage-perl` viejo junto a un PVE nuevo es más riesgoso: oculta
incompatibilidades y retiene fixes de seguridad.

Se implementó un hook transaccional de APT instalado en cada nodo. Cuando
existe una sección `zfsnvme:` en `storage.cfg`, inspecciona el contenido de
cada paquete candidato antes de `dpkg` y bloquea:

- un `libpve-storage-perl` sin el backend nativo;
- un `pve-manager` sin el editor correspondiente.

Si un paquete oficial futuro ya contiene el feature, el guard lo acepta por
contenido, no por el sufijo `+neatech`. El flujo de release recomendado es
rebasear sobre el source exacto de PVE, ejecutar toda la matriz, construir una
versión superior a la oficial en un APT privado firmado y desplegar rolling
con el nodo drenado.

## 5. Topología de validación

Target `kbuild01`:

- management: `192.168.34.11`;
- path A: `ens20`, `10.90.1.11:4421`;
- path B: `ens21`, `10.90.2.11:4421`;
- Ubuntu kernel `6.8.0-134-generic`;
- OpenZFS `2.2.2-0ubuntu9.4`;
- pool `tank`, 23.5 GiB, ONLINE;
- dataset `tank/pve-nvme`;
- NQN `nqn.2026-07.ar.neatech:pve-zfsnvme-test`.

Initiators PVE 9.2:

- `pvenest01`: management `192.168.34.14`, paths `10.90.1.14` y
  `10.90.2.14`;
- `pvenest02`: management `192.168.34.16`, paths `10.90.1.16` y
  `10.90.2.16`;
- kernel `7.0.14-4-pve`;
- `nvme-cli 2.13`, `libnvme 1.13`;
- dos Host NQN diferentes;
- QDevice como tercer voto y watchdog de HA armado.

El storage iSCSI anterior y la VM 8888 permanecieron activos como control de
regresión mientras se hicieron las pruebas NVMe/TCP.

## 6. Pruebas automatizadas

El build final desde el commit publicado ejecutó:

| Suite | Assertions | Resultado |
| --- | ---: | --- |
| disk tests | 7 | PASS |
| bandwidth-limit | 91 | PASS |
| plugin tests, incluido `zfsnvme` | 200 | PASS |
| OVF | 35 | PASS |
| volume access | 183 | PASS |
| parser Ceph | 74 | PASS |
| Total | 590 | PASS |

Además pasó la verificación del API Perl. Los tests ZFS/LVM del harness que
requieren root se saltearon en ese runner no privilegiado; la integración ZFS
real se cubrió directamente contra `tank/pve-nvme`.

Se agregaron casos específicos para parsing estricto, correspondencia portal
/interfaz, secretos, ownership, identidad, conflicto de NQN, rechazo de resize
online, preflight de interfaz ausente, deactivación con un QEMU simulado y
remoción con dataset no vacío.

## 7. Pruebas funcionales integradas

Se verificaron en el clúster:

- alta thin y exposición del zvol como namespace;
- escritura/lectura desde una VM real;
- reclaim por discard desde un scratch volume con guardas destructivas;
- snapshot y rollback con restitución exacta de checksum;
- snapshot online;
- conversión a template;
- linked clone y posterior eliminación;
- resize offline;
- rechazo temprano de resize online, sin cambiar `volsize`;
- eliminación sin residuos del zvol y del namespace;
- reconstrucción de configfs usando solamente propiedades ZFS;
- rechazo de un zvol perteneciente al target iSCSI anterior;
- path estable por UUID en ambos nodos;
- activación en el destino antes de que QEMU abra el disco.

## 8. Migración y HA

La migración en vivo se ejecutó en ambos sentidos bajo I/O del guest. También
se migró hacia un destino que tenía un path degradado. En todos los casos el
destino resolvió el mismo UUID de namespace antes de abrirlo.

Para la prueba HA se creó el scratch VMID 9210, se lo puso bajo HA y se detuvo
Corosync en `pvenest01`. El watchdog reinició el nodo; QDevice mantuvo quorum y
el master sobreviviente esperó confirmación de fencing antes de iniciar la VM.

Resultados:

- inicio de la falla: 03:56:58 UTC;
- VM iniciada en `pvenest02`: 04:01:03 UTC;
- recovery end-to-end: 245 segundos con los timers default del lab;
- mismo namespace UUID en el destino;
- dos paths `live` al finalizar;
- cero failed block operations;
- sin ventana de doble escritor observada.

El VMID 9210 y su zvol fueron purgados después de la prueba. VM 8888 siguió
corriendo en el storage de control.

## 9. Fault injection y reliability

### Pérdida de un path

Se bajó una red de datos completa. El controller correspondiente pasó a estado
de falla y el I/O siguió por el path restante. Al restaurarlo, el controller
volvió `live` y el namespace continuó siendo el mismo.

### Pérdida simultánea de ambos paths

Se cortaron ambos paths durante 15 segundos. La capa de bloques aplicó
backpressure; no devolvió errores al guest. Al recuperar conectividad, el I/O
continuó y el checksum final fue válido.

### Interfaz equivocada

Se indujo una conexión que no respetaba `host_iface`. El reconciler reemplazó
controllers de a uno, manteniendo servicio por el otro path.

### Pérdida de configfs

Se eliminó estado derivado del target y se forzó reconcile. Namespaces, UUID,
ACL y portales se reconstruyeron desde la identidad persistida en ZFS.

### Caída del management SSH

Se bloqueó solamente SSH entre el initiator y `192.168.34.11`:

- los dos controllers NVMe/TCP siguieron `live`;
- el I/O conectado permaneció independiente;
- `pvesm status` marcó inactivo en aproximadamente 2012 ms porque no podía
  consultar capacidad;
- un allocate de prueba falló limpiamente;
- no quedó zvol residual;
- al restaurar SSH, el storage volvió a activo.

### Guardas de teardown

Con una VM usando `/dev/nvme0n1`, el scanner reportó el proceso KVM y
`deactivate_storage` rechazó la desconexión. Con el dataset conteniendo
`base-9200-disk-0`, `on_delete_hook` rechazó la remoción aun cuando se invocó
desde el otro nodo. Una vez sin consumidores, la deactivación y reconexión
normal funcionaron con dos paths.

## 10. Performance

El workload fue `fio` con `io_uring`, escritura directa, bloque de 128 KiB,
iodepth 32, cuatro jobs, 20 segundos y 3 segundos de ramp. Para medir scaling,
cada interfaz recibió un TBF de 100 Mbit/s.

| Escenario | MB/s | IOPS | Observación |
| --- | ---: | ---: | --- |
| solo path A, 100 Mbit/s | 11.94 | 85.3 | PASS |
| solo path B, 100 Mbit/s | 11.94 | 85.3 | PASS |
| A+B, 2×100 Mbit/s | 23.89 | 176.3 | PASS |
| A+B, sin shaping | 131.96 | 1000.7 | muestra del lab |

El dual path entregó 2.00× el throughput de un path. Los 11.94 MB/s equivalen
aproximadamente al 95.5 % del límite decimal de 100 Mbit/s; el resultado dual
mantiene prácticamente la misma eficiencia agregada. Esto demuestra uso
concurrente de paths y balanceo en el lab, no capacidad de hardware enterprise.

## 11. Estado final del lab

Al cierre:

- `zfsnvmetest` está `active` en ambos nodos;
- ambos nodos tienen dos controllers `live`, uno por `ens20` y otro por
  `ens21`;
- los servicios `pvedaemon`, `pvestatd`, `pveproxy` y `pve-ha-lrm` están
  activos;
- el clúster está quorate con QDevice;
- fencing está armado;
- VM 8888 está running en `pvenest02`;
- el target tiene un namespace durable, `base-9200-disk-0`, y dos ACL de Host
  NQN;
- `tank` está ONLINE;
- no quedó el scratch VMID 9210.

Paquetes instalados en ambos nodos:

- `libpve-storage-perl 9.1.6+neatech3`;
- `pve-manager 9.2.4+neatech1`;
- `pve-docs 9.2.3+neatech4`;
- `pve-doc-generator 9.2.3+neatech4`.

## 12. Qué falta antes de una certificación enterprise

La deuda restante no es un bug conocido del plugin; es calificación del
entorno final:

1. soak de al menos 72 horas con mezcla read/write, sync/async, discard y
   snapshots sobre el hardware real;
2. latencias p50/p95/p99/p99.9 y recovery time bajo carga sostenida;
3. pérdida de NIC, cable, switch, VLAN y portal físico;
4. reboot del target y de cada initiator;
5. pool casi lleno y completamente lleno;
6. restore real desde backup y validación de RPO/RTO;
7. rolling upgrade con los paquetes candidatos exactos;
8. revisión de seguridad y decisión explícita entre red aislada y TLS;
9. publicación en APT privado firmado hasta lograr upstream;
10. RFC y rondas de review en `pve-devel`.

Hasta completar esa matriz, la clasificación correcta es “candidato de release
con validación funcional, de fallos y HA en lab”, no una certificación universal
para cualquier plataforma.

## 13. Repositorios

- Backend: <https://github.com/joaquinv98/pve-storage/tree/feature/zfs-nvme-tcp>
- UI: <https://github.com/joaquinv98/pve-manager/tree/feature/zfs-nvme-tcp>
- Documentación: <https://github.com/joaquinv98/pve-docs/tree/feature/zfs-nvme-tcp>

La versión machine-readable de este informe está en
`docs/validation-results.json`.
