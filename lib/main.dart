import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;
import 'package:url_launcher/url_launcher.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Avisos.i.iniciar();
  await Avisos.i.reprogramar();
  runApp(const JsusISP());
}

class JsusISP extends StatelessWidget {
  const JsusISP({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'JSUS ISP',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        scaffoldBackgroundColor: C.bg,
        colorScheme: const ColorScheme.dark(
          primary: C.up,
          surface: C.surface,
          error: C.down,
        ),
        snackBarTheme: const SnackBarThemeData(
          contentTextStyle: TextStyle(color: C.text),
        ),
      ),
      home: const Inicio(),
    );
  }
}


// ===========================================================================
// PALETA — "link status" : el estado del enlace es el lenguaje visual
// ===========================================================================
class C {
  static const bg = Color(0xFF0E1116);
  static const surface = Color(0xFF171B22);
  static const surfaceAlt = Color(0xFF1F252E);
  static const line = Color(0xFF2A313C);
  static const text = Color(0xFFE6EAF0);
  static const muted = Color(0xFF8A94A6);

  static const up = Color(0xFF22D3A6); // al día
  static const warn = Color(0xFFF2B33D); // vence pronto
  static const down = Color(0xFFF4544E); // vencido
  static const off = Color(0xFF5A6474); // inactivo
}

const mono = 'monospace';

// ===========================================================================
// MODELOS
// ===========================================================================
enum Estado { alDia, venceManana, porVencer, vencido, inactivo }

extension EstadoInfo on Estado {
  String get texto => switch (this) {
        Estado.alDia => 'Al día',
        Estado.venceManana => 'Vence mañana',
        Estado.porVencer => 'Por vencer',
        Estado.vencido => 'Vencido',
        Estado.inactivo => 'Inactivo',
      };

  Color get color => switch (this) {
        Estado.alDia => C.up,
        Estado.venceManana => C.warn,
        Estado.porVencer => C.warn,
        Estado.vencido => C.down,
        Estado.inactivo => C.off,
      };
}

class Cliente {
  int? id;
  String nombre;
  String telefono;
  String ip;
  String mac;
  String plan;
  double precio;
  int diaPago; // 1..28
  bool activo;
  String notas;

  Cliente({
    this.id,
    required this.nombre,
    required this.telefono,
    this.ip = '',
    this.mac = '',
    this.plan = '',
    this.precio = 0,
    required this.diaPago,
    this.activo = true,
    this.notas = '',
  });

  Map<String, Object?> toMap() => {
        'id': id,
        'nombre': nombre,
        'telefono': telefono,
        'ip': ip,
        'mac': mac,
        'plan': plan,
        'precio': precio,
        'diaPago': diaPago,
        'activo': activo ? 1 : 0,
        'notas': notas,
      };

  factory Cliente.fromMap(Map<String, Object?> m) => Cliente(
        id: m['id'] as int?,
        nombre: (m['nombre'] ?? '') as String,
        telefono: (m['telefono'] ?? '') as String,
        ip: (m['ip'] ?? '') as String,
        mac: (m['mac'] ?? '') as String,
        plan: (m['plan'] ?? '') as String,
        precio: (m['precio'] as num?)?.toDouble() ?? 0,
        diaPago: (m['diaPago'] as int?) ?? 1,
        activo: ((m['activo'] as int?) ?? 1) == 1,
        notas: (m['notas'] ?? '') as String,
      );

  /// Día en que se dispara el aviso (24 h antes).
  int get diaAviso => diaPago > 1 ? diaPago - 1 : 28;

  String get telefonoLimpio => telefono.replaceAll(RegExp(r'[^0-9]'), '');
}

class Pago {
  int? id;
  int clienteId;
  double monto;
  String fecha; // ISO yyyy-MM-dd
  String periodo; // yyyy-MM
  String nota;

  Pago({
    this.id,
    required this.clienteId,
    required this.monto,
    required this.fecha,
    required this.periodo,
    this.nota = '',
  });

  Map<String, Object?> toMap() => {
        'id': id,
        'clienteId': clienteId,
        'monto': monto,
        'fecha': fecha,
        'periodo': periodo,
        'nota': nota,
      };

  factory Pago.fromMap(Map<String, Object?> m) => Pago(
        id: m['id'] as int?,
        clienteId: m['clienteId'] as int,
        monto: (m['monto'] as num).toDouble(),
        fecha: m['fecha'] as String,
        periodo: m['periodo'] as String,
        nota: (m['nota'] ?? '') as String,
      );
}

String periodoActual([DateTime? d]) {
  final f = d ?? DateTime.now();
  return '${f.year}-${f.month.toString().padLeft(2, '0')}';
}

String hoyISO() {
  final f = DateTime.now();
  return '${f.year}-${f.month.toString().padLeft(2, '0')}-'
      '${f.day.toString().padLeft(2, '0')}';
}

// ===========================================================================
// BASE DE DATOS
// ===========================================================================
class DB {
  DB._();
  static final DB i = DB._();
  Database? _db;

  Future<Database> get db async => _db ??= await _abrir();

  Future<Database> _abrir() async {
    final ruta = p.join(await getDatabasesPath(), 'jsus_isp.db');
    return openDatabase(ruta, version: 1, onCreate: (d, _) async {
      await d.execute('''
        CREATE TABLE clientes(
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          nombre TEXT NOT NULL,
          telefono TEXT NOT NULL,
          ip TEXT, mac TEXT, plan TEXT,
          precio REAL NOT NULL DEFAULT 0,
          diaPago INTEGER NOT NULL,
          activo INTEGER NOT NULL DEFAULT 1,
          notas TEXT
        )''');
      await d.execute('''
        CREATE TABLE pagos(
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          clienteId INTEGER NOT NULL,
          monto REAL NOT NULL,
          fecha TEXT NOT NULL,
          periodo TEXT NOT NULL,
          nota TEXT
        )''');
      await d.execute(
          'CREATE TABLE config(clave TEXT PRIMARY KEY, valor TEXT)');
    });
  }

  // ---- clientes ----
  Future<List<Cliente>> clientes() async {
    final d = await db;
    final r = await d.query('clientes', orderBy: 'diaPago ASC, nombre ASC');
    return r.map(Cliente.fromMap).toList();
  }

  Future<Cliente?> cliente(int id) async {
    final d = await db;
    final r = await d.query('clientes', where: 'id=?', whereArgs: [id]);
    return r.isEmpty ? null : Cliente.fromMap(r.first);
  }

  Future<int> guardarCliente(Cliente c) async {
    final d = await db;
    if (c.id == null) {
      c.id = await d.insert('clientes', c.toMap()..remove('id'));
    } else {
      await d.update('clientes', c.toMap(), where: 'id=?', whereArgs: [c.id]);
    }
    await Avisos.i.reprogramar();
    return c.id!;
  }

  Future<void> borrarCliente(int id) async {
    final d = await db;
    await d.delete('pagos', where: 'clienteId=?', whereArgs: [id]);
    await d.delete('clientes', where: 'id=?', whereArgs: [id]);
    await Avisos.i.reprogramar();
  }

  // ---- pagos ----
  Future<List<Pago>> pagos({int? clienteId, int limite = 200}) async {
    final d = await db;
    final r = await d.query('pagos',
        where: clienteId == null ? null : 'clienteId=?',
        whereArgs: clienteId == null ? null : [clienteId],
        orderBy: 'fecha DESC, id DESC',
        limit: limite);
    return r.map(Pago.fromMap).toList();
  }

  Future<void> registrarPago(Pago pago) async {
    final d = await db;
    await d.delete('pagos',
        where: 'clienteId=? AND periodo=?',
        whereArgs: [pago.clienteId, pago.periodo]);
    await d.insert('pagos', pago.toMap()..remove('id'));
  }

  Future<void> borrarPago(int id) async {
    final d = await db;
    await d.delete('pagos', where: 'id=?', whereArgs: [id]);
  }

  Future<Set<int>> pagadosEn(String periodo) async {
    final d = await db;
    final r = await d
        .query('pagos', columns: ['clienteId'], where: 'periodo=?', whereArgs: [periodo]);
    return r.map((e) => e['clienteId'] as int).toSet();
  }

  // ---- config ----
  Future<String> leer(String clave, String porDefecto) async {
    final d = await db;
    final r = await d.query('config', where: 'clave=?', whereArgs: [clave]);
    return r.isEmpty ? porDefecto : (r.first['valor'] as String);
  }

  Future<void> escribir(String clave, String valor) async {
    final d = await db;
    await d.insert('config', {'clave': clave, 'valor': valor},
        conflictAlgorithm: ConflictAlgorithm.replace);
  }
}

// ===========================================================================
// ESTADO DE COBRO
// ===========================================================================
Estado estadoDe(Cliente c, Set<int> pagados) {
  if (!c.activo) return Estado.inactivo;
  if (pagados.contains(c.id)) return Estado.alDia;
  final hoy = DateTime.now().day;
  if (hoy > c.diaPago) return Estado.vencido;
  if (hoy == c.diaPago - 1) return Estado.venceManana;
  if (c.diaPago - hoy <= 5) return Estado.porVencer;
  return Estado.alDia;
}

// ===========================================================================
// AVISOS (notificaciones locales, mensuales, 24 h antes)
// ===========================================================================
class Avisos {
  Avisos._();
  static final Avisos i = Avisos._();
  final plugin = FlutterLocalNotificationsPlugin();

  static int? clientePendiente; // id recibido al tocar la notificación

  Future<void> iniciar() async {
    tzdata.initializeTimeZones();
    try {
      tz.setLocalLocation(tz.getLocation('America/Havana'));
    } catch (_) {}

    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    await plugin.initialize(
      const InitializationSettings(android: android),
      onDidReceiveNotificationResponse: (r) {
        final id = int.tryParse(r.payload ?? '');
        if (id != null) clientePendiente = id;
      },
    );

    final det = await plugin.getNotificationAppLaunchDetails();
    if (det?.didNotificationLaunchApp ?? false) {
      final id = int.tryParse(det?.notificationResponse?.payload ?? '');
      if (id != null) clientePendiente = id;
    }

    final a = plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    await a?.requestNotificationsPermission();
    await a?.requestExactAlarmsPermission();
  }

  Future<void> reprogramar() async {
    await plugin.cancelAll();

    final hora = int.parse(await DB.i.leer('hora', '9'));
    final minuto = int.parse(await DB.i.leer('minuto', '0'));
    final plantilla = await DB.i.leer('plantilla', plantillaPorDefecto);
    final clientes = await DB.i.clientes();

    const det = NotificationDetails(
      android: AndroidNotificationDetails(
        'cobros',
        'Recordatorios de cobro',
        channelDescription: 'Aviso 24 horas antes del día de pago',
        importance: Importance.max,
        priority: Priority.high,
      ),
    );

    for (final c in clientes) {
      if (!c.activo || c.id == null) continue;
      await plugin.zonedSchedule(
        c.id!,
        '${c.nombre} paga mañana',
        armarMensaje(plantilla, c).replaceAll('\n', ' '),
        _proxima(c.diaAviso, hora, minuto),
        det,
        androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
        matchDateTimeComponents: DateTimeComponents.dayOfMonthAndTime,
        payload: '${c.id}',
      );
    }
  }

  tz.TZDateTime _proxima(int dia, int hora, int minuto) {
    final ahora = tz.TZDateTime.now(tz.local);
    var t = tz.TZDateTime(tz.local, ahora.year, ahora.month, dia, hora, minuto);
    if (!t.isAfter(ahora)) {
      t = tz.TZDateTime(tz.local, ahora.year, ahora.month + 1, dia, hora, minuto);
    }
    return t;
  }

  Future<void> prueba() async {
    await plugin.show(
      999999,
      'Prueba de aviso',
      'Si ves esto, los recordatorios funcionan.',
      const NotificationDetails(
        android: AndroidNotificationDetails('cobros', 'Recordatorios de cobro',
            importance: Importance.max, priority: Priority.high),
      ),
    );
  }
}

// ===========================================================================
// MENSAJE Y WHATSAPP
// ===========================================================================
const plantillaPorDefecto =
    'Hola {nombre}, te recuerdo que mañana {dia} vence tu pago de {precio} USD '
    'del {plan}. Cualquier duda escríbeme. Gracias.';

String armarMensaje(String plantilla, Cliente c) => plantilla
    .replaceAll('{nombre}', c.nombre)
    .replaceAll('{dia}', '${c.diaPago}')
    .replaceAll('{precio}', c.precio.toStringAsFixed(2))
    .replaceAll('{plan}', c.plan.isEmpty ? 'servicio' : c.plan)
    .replaceAll('{ip}', c.ip);

Future<bool> abrirWhatsApp(Cliente c, String mensaje) async {
  final n = c.telefonoLimpio;
  if (n.isEmpty) return false;
  final uri = Uri.parse('https://wa.me/$n?text=${Uri.encodeComponent(mensaje)}');
  return launchUrl(uri, mode: LaunchMode.externalApplication);
}


// ===========================================================================
// WIDGETS COMPARTIDOS
// ===========================================================================

/// Tarjeta con barra de estado a la izquierda — la "luz de enlace" del cliente.
class TarjetaCliente extends StatelessWidget {
  final Cliente cliente;
  final Estado estado;
  final VoidCallback? onTap;
  final VoidCallback? onWhatsApp;
  final VoidCallback? onCobrar;

  const TarjetaCliente({
    super.key,
    required this.cliente,
    required this.estado,
    this.onTap,
    this.onWhatsApp,
    this.onCobrar,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: C.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: C.line),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(width: 4, color: estado.color),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(cliente.nombre,
                                style: const TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.w600,
                                    color: C.text)),
                          ),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 3),
                            decoration: BoxDecoration(
                              color: estado.color.withValues(alpha: 0.14),
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: Text(estado.texto,
                                style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w600,
                                    color: estado.color)),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Text(
                        'Día ${cliente.diaPago}  ·  '
                        '${cliente.precio.toStringAsFixed(2)} USD'
                        '${cliente.plan.isEmpty ? '' : '  ·  ${cliente.plan}'}',
                        style: const TextStyle(
                            fontSize: 12.5, color: C.muted, fontFamily: mono),
                      ),
                      if (cliente.ip.isNotEmpty || cliente.mac.isNotEmpty) ...[
                        const SizedBox(height: 3),
                        Text(
                          [cliente.ip, cliente.mac]
                              .where((e) => e.isNotEmpty)
                              .join('  ·  '),
                          style: const TextStyle(
                              fontSize: 11.5,
                              color: C.off,
                              fontFamily: mono),
                        ),
                      ],
                      if (onWhatsApp != null || onCobrar != null) ...[
                        const SizedBox(height: 8),
                        Row(children: [
                          if (onWhatsApp != null)
                            _MiniBoton(
                                icono: Icons.chat_bubble_outline,
                                texto: 'WhatsApp',
                                color: C.up,
                                onTap: onWhatsApp!),
                          if (onWhatsApp != null && onCobrar != null)
                            const SizedBox(width: 8),
                          if (onCobrar != null)
                            _MiniBoton(
                                icono: Icons.check_circle_outline,
                                texto: 'Registrar pago',
                                color: C.muted,
                                onTap: onCobrar!),
                        ]),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MiniBoton extends StatelessWidget {
  final IconData icono;
  final String texto;
  final Color color;
  final VoidCallback onTap;
  const _MiniBoton(
      {required this.icono,
      required this.texto,
      required this.color,
      required this.onTap});

  @override
  Widget build(BuildContext context) => InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            border: Border.all(color: color.withValues(alpha: 0.4)),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(icono, size: 14, color: color),
            const SizedBox(width: 5),
            Text(texto,
                style: TextStyle(
                    fontSize: 12, color: color, fontWeight: FontWeight.w500)),
          ]),
        ),
      );
}

class _Metrica extends StatelessWidget {
  final String valor, etiqueta;
  final Color color;
  const _Metrica(this.valor, this.etiqueta, this.color);

  @override
  Widget build(BuildContext context) => Expanded(
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 10),
          decoration: BoxDecoration(
            color: C.surface,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: C.line),
          ),
          child: Column(children: [
            Text(valor,
                style: TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.w700,
                    color: color,
                    fontFamily: mono)),
            const SizedBox(height: 2),
            Text(etiqueta,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 11, color: C.muted)),
          ]),
        ),
      );
}

Widget _vacio(String titulo, String ayuda) => Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.router_outlined, size: 44, color: C.off),
          const SizedBox(height: 12),
          Text(titulo,
              textAlign: TextAlign.center,
              style: const TextStyle(color: C.text, fontSize: 16)),
          const SizedBox(height: 6),
          Text(ayuda,
              textAlign: TextAlign.center,
              style: const TextStyle(color: C.muted, fontSize: 13)),
        ]),
      ),
    );

void aviso(BuildContext ctx, String texto) {
  ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(
    content: Text(texto),
    backgroundColor: C.surfaceAlt,
    behavior: SnackBarBehavior.floating,
  ));
}

// ===========================================================================
// CONTENEDOR PRINCIPAL
// ===========================================================================
class Inicio extends StatefulWidget {
  const Inicio({super.key});
  @override
  State<Inicio> createState() => InicioState();
}

class InicioState extends State<Inicio> {
  int _tab = 0;
  final _key = GlobalKey<_PanelState>();

  void recargar() => setState(() {});

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _revisarPendiente());
  }

  Future<void> _revisarPendiente() async {
    final id = Avisos.clientePendiente;
    if (id == null) return;
    Avisos.clientePendiente = null;
    final c = await DB.i.cliente(id);
    if (c == null || !mounted) return;
    final plantilla = await DB.i.leer('plantilla', plantillaPorDefecto);
    final ok = await abrirWhatsApp(c, armarMensaje(plantilla, c));
    if (!ok && mounted) aviso(context, 'No se pudo abrir WhatsApp');
  }

  @override
  Widget build(BuildContext context) {
    final paginas = [
      Panel(key: _key, onCambio: recargar),
      ListaClientes(onCambio: recargar),
      const HistorialPagos(),
    ];

    return Scaffold(
      backgroundColor: C.bg,
      body: SafeArea(child: paginas[_tab]),
      bottomNavigationBar: NavigationBar(
        backgroundColor: C.surface,
        indicatorColor: C.up.withValues(alpha: 0.16),
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: const [
          NavigationDestination(
              icon: Icon(Icons.dashboard_outlined),
              selectedIcon: Icon(Icons.dashboard, color: C.up),
              label: 'Panel'),
          NavigationDestination(
              icon: Icon(Icons.people_outline),
              selectedIcon: Icon(Icons.people, color: C.up),
              label: 'Clientes'),
          NavigationDestination(
              icon: Icon(Icons.receipt_long_outlined),
              selectedIcon: Icon(Icons.receipt_long, color: C.up),
              label: 'Pagos'),
        ],
      ),
    );
  }
}

// ===========================================================================
// 1. PANEL
// ===========================================================================
class Panel extends StatefulWidget {
  final VoidCallback onCambio;
  const Panel({super.key, required this.onCambio});
  @override
  State<Panel> createState() => _PanelState();
}

class _PanelState extends State<Panel> {
  List<Cliente> _clientes = [];
  Set<int> _pagados = {};
  bool _cargando = true;

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  Future<void> _cargar() async {
    final c = await DB.i.clientes();
    final p = await DB.i.pagadosEn(periodoActual());
    if (!mounted) return;
    setState(() {
      _clientes = c;
      _pagados = p;
      _cargando = false;
    });
  }

  Future<void> _whatsapp(Cliente c) async {
    final plantilla = await DB.i.leer('plantilla', plantillaPorDefecto);
    final ok = await abrirWhatsApp(c, armarMensaje(plantilla, c));
    if (!ok && mounted) aviso(context, 'Ese cliente no tiene teléfono válido');
  }

  Future<void> _cobrar(Cliente c) async {
    await DB.i.registrarPago(Pago(
      clienteId: c.id!,
      monto: c.precio,
      fecha: hoyISO(),
      periodo: periodoActual(),
    ));
    await _cargar();
    if (mounted) aviso(context, 'Pago de ${c.nombre} registrado');
  }

  @override
  Widget build(BuildContext context) {
    if (_cargando) {
      return const Center(child: CircularProgressIndicator(color: C.up));
    }

    final activos = _clientes.where((c) => c.activo).toList();
    final estados = {for (final c in activos) c.id: estadoDe(c, _pagados)};
    final manana =
        activos.where((c) => estados[c.id] == Estado.venceManana).toList();
    final vencidos =
        activos.where((c) => estados[c.id] == Estado.vencido).toList();
    final pronto =
        activos.where((c) => estados[c.id] == Estado.porVencer).toList();
    final cobrado = activos
        .where((c) => _pagados.contains(c.id))
        .fold<double>(0, (s, c) => s + c.precio);

    return RefreshIndicator(
      color: C.up,
      backgroundColor: C.surface,
      onRefresh: _cargar,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(14, 16, 14, 24),
        children: [
          Row(
            children: [
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('JSUS ISP',
                        style: TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 1.5,
                            color: C.text)),
                    Text('Control de cobros',
                        style: TextStyle(fontSize: 12.5, color: C.muted)),
                  ],
                ),
              ),
              IconButton(
                icon: const Icon(Icons.tune, color: C.muted),
                onPressed: () async {
                  await Navigator.push(
                      context,
                      MaterialPageRoute(
                          builder: (_) => const Ajustes()));
                  _cargar();
                },
              ),
            ],
          ),
          const SizedBox(height: 16),
          Row(children: [
            _Metrica('${activos.length}', 'Clientes activos', C.text),
            const SizedBox(width: 10),
            _Metrica('${vencidos.length}', 'Vencidos', C.down),
            const SizedBox(width: 10),
            _Metrica(cobrado.toStringAsFixed(0), 'Cobrado este mes', C.up),
          ]),
          const SizedBox(height: 22),
          if (activos.isEmpty)
            _vacio('Todavía no hay clientes',
                'Agrega tu primer cliente desde la pestaña Clientes.'),
          if (manana.isNotEmpty) ...[
            _Seccion('Vencen mañana', manana.length, C.warn),
            ...manana.map((c) => TarjetaCliente(
                  cliente: c,
                  estado: Estado.venceManana,
                  onWhatsApp: () => _whatsapp(c),
                  onCobrar: () => _cobrar(c),
                )),
            const SizedBox(height: 14),
          ],
          if (vencidos.isNotEmpty) ...[
            _Seccion('Vencidos', vencidos.length, C.down),
            ...vencidos.map((c) => TarjetaCliente(
                  cliente: c,
                  estado: Estado.vencido,
                  onWhatsApp: () => _whatsapp(c),
                  onCobrar: () => _cobrar(c),
                )),
            const SizedBox(height: 14),
          ],
          if (pronto.isNotEmpty) ...[
            _Seccion('Próximos 5 días', pronto.length, C.warn),
            ...pronto.map((c) => TarjetaCliente(
                  cliente: c,
                  estado: Estado.porVencer,
                  onWhatsApp: () => _whatsapp(c),
                  onCobrar: () => _cobrar(c),
                )),
          ],
          if (activos.isNotEmpty &&
              manana.isEmpty &&
              vencidos.isEmpty &&
              pronto.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 30),
              child: Column(children: [
                const Icon(Icons.check_circle_outline, size: 40, color: C.up),
                const SizedBox(height: 10),
                const Text('Todo al día',
                    style: TextStyle(color: C.text, fontSize: 16)),
                const SizedBox(height: 4),
                Text('Ningún cliente vence en los próximos 5 días.',
                    style: const TextStyle(color: C.muted, fontSize: 13)),
              ]),
            ),
        ],
      ),
    );
  }
}

class _Seccion extends StatelessWidget {
  final String titulo;
  final int cuenta;
  final Color color;
  const _Seccion(this.titulo, this.cuenta, this.color);

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Row(children: [
          Container(width: 8, height: 8,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
          const SizedBox(width: 8),
          Text(titulo.toUpperCase(),
              style: const TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.2,
                  color: C.muted)),
          const SizedBox(width: 6),
          Text('$cuenta',
              style: TextStyle(
                  fontSize: 11.5, color: color, fontFamily: mono)),
        ]),
      );
}

// ===========================================================================
// 2. CLIENTES
// ===========================================================================
class ListaClientes extends StatefulWidget {
  final VoidCallback onCambio;
  const ListaClientes({super.key, required this.onCambio});
  @override
  State<ListaClientes> createState() => _ListaClientesState();
}

class _ListaClientesState extends State<ListaClientes> {
  List<Cliente> _todos = [];
  Set<int> _pagados = {};
  String _busca = '';

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  Future<void> _cargar() async {
    final c = await DB.i.clientes();
    final p = await DB.i.pagadosEn(periodoActual());
    if (!mounted) return;
    setState(() {
      _todos = c;
      _pagados = p;
    });
    widget.onCambio();
  }

  Future<void> _editar([Cliente? c]) async {
    final guardado = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => FormCliente(cliente: c)),
    );
    if (guardado == true) _cargar();
  }

  @override
  Widget build(BuildContext context) {
    final lista = _todos
        .where((c) =>
            c.nombre.toLowerCase().contains(_busca.toLowerCase()) ||
            c.ip.contains(_busca) ||
            c.telefono.contains(_busca))
        .toList();

    return Scaffold(
      backgroundColor: C.bg,
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: C.up,
        foregroundColor: C.bg,
        onPressed: () => _editar(),
        icon: const Icon(Icons.add),
        label: const Text('Nuevo cliente'),
      ),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 16, 14, 10),
          child: TextField(
            style: const TextStyle(color: C.text),
            onChanged: (v) => setState(() => _busca = v),
            decoration: InputDecoration(
              hintText: 'Buscar por nombre, IP o teléfono',
              hintStyle: const TextStyle(color: C.off, fontSize: 14),
              prefixIcon: const Icon(Icons.search, color: C.off, size: 20),
              filled: true,
              fillColor: C.surface,
              contentPadding: const EdgeInsets.symmetric(vertical: 4),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: const BorderSide(color: C.line),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: const BorderSide(color: C.line),
              ),
            ),
          ),
        ),
        Expanded(
          child: lista.isEmpty
              ? _vacio(
                  _todos.isEmpty ? 'Sin clientes' : 'Nada coincide',
                  _todos.isEmpty
                      ? 'Toca Nuevo cliente para registrar el primero.'
                      : 'Prueba con otro término de búsqueda.')
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(14, 0, 14, 90),
                  itemCount: lista.length,
                  itemBuilder: (_, i) {
                    final c = lista[i];
                    return TarjetaCliente(
                      cliente: c,
                      estado: estadoDe(c, _pagados),
                      onTap: () => _editar(c),
                    );
                  },
                ),
        ),
      ]),
    );
  }
}

class FormCliente extends StatefulWidget {
  final Cliente? cliente;
  const FormCliente({super.key, this.cliente});
  @override
  State<FormCliente> createState() => _FormClienteState();
}

class _FormClienteState extends State<FormCliente> {
  final _form = GlobalKey<FormState>();
  late TextEditingController _nombre, _tel, _ip, _mac, _plan, _precio, _notas;
  int _dia = 1;
  bool _activo = true;

  @override
  void initState() {
    super.initState();
    final c = widget.cliente;
    _nombre = TextEditingController(text: c?.nombre ?? '');
    _tel = TextEditingController(text: c?.telefono ?? '53');
    _ip = TextEditingController(text: c?.ip ?? '192.168.10.');
    _mac = TextEditingController(text: c?.mac ?? '');
    _plan = TextEditingController(text: c?.plan ?? '');
    _precio =
        TextEditingController(text: c == null ? '' : c.precio.toStringAsFixed(2));
    _notas = TextEditingController(text: c?.notas ?? '');
    _dia = c?.diaPago ?? 1;
    _activo = c?.activo ?? true;
  }

  @override
  void dispose() {
    for (final c in [_nombre, _tel, _ip, _mac, _plan, _precio, _notas]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _guardar() async {
    if (!_form.currentState!.validate()) return;
    final c = widget.cliente ??
        Cliente(nombre: '', telefono: '', diaPago: 1);
    c.nombre = _nombre.text.trim();
    c.telefono = _tel.text.trim();
    c.ip = _ip.text.trim();
    c.mac = _mac.text.trim();
    c.plan = _plan.text.trim();
    c.precio = double.tryParse(_precio.text.replaceAll(',', '.')) ?? 0;
    c.diaPago = _dia;
    c.activo = _activo;
    c.notas = _notas.text.trim();
    await DB.i.guardarCliente(c);
    if (mounted) Navigator.pop(context, true);
  }

  Future<void> _borrar() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: C.surfaceAlt,
        title: const Text('Eliminar cliente', style: TextStyle(color: C.text)),
        content: Text(
            'Se borra ${widget.cliente!.nombre} y todo su historial de pagos.',
            style: const TextStyle(color: C.muted)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancelar',
                  style: TextStyle(color: C.muted))),
          TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Eliminar',
                  style: TextStyle(color: C.down))),
        ],
      ),
    );
    if (ok == true) {
      await DB.i.borrarCliente(widget.cliente!.id!);
      if (mounted) Navigator.pop(context, true);
    }
  }

  InputDecoration _dec(String label, {String? ayuda}) => InputDecoration(
        labelText: label,
        helperText: ayuda,
        helperStyle: const TextStyle(color: C.off, fontSize: 11.5),
        labelStyle: const TextStyle(color: C.muted, fontSize: 14),
        filled: true,
        fillColor: C.surface,
        border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: const BorderSide(color: C.line)),
        enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: const BorderSide(color: C.line)),
        focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: const BorderSide(color: C.up)),
      );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: C.bg,
      appBar: AppBar(
        backgroundColor: C.bg,
        foregroundColor: C.text,
        title: Text(widget.cliente == null ? 'Nuevo cliente' : 'Editar cliente'),
        actions: [
          if (widget.cliente != null)
            IconButton(
                icon: const Icon(Icons.delete_outline, color: C.down),
                onPressed: _borrar),
        ],
      ),
      body: Form(
        key: _form,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(14, 8, 14, 30),
          children: [
            TextFormField(
              controller: _nombre,
              style: const TextStyle(color: C.text),
              decoration: _dec('Nombre'),
              validator: (v) =>
                  (v == null || v.trim().isEmpty) ? 'Escribe el nombre' : null,
            ),
            const SizedBox(height: 14),
            TextFormField(
              controller: _tel,
              style: const TextStyle(color: C.text, fontFamily: mono),
              keyboardType: TextInputType.phone,
              decoration: _dec('Teléfono',
                  ayuda: 'Con código de país, sin +. Ejemplo: 5351234567'),
              validator: (v) {
                final n = (v ?? '').replaceAll(RegExp(r'[^0-9]'), '');
                return n.length < 8 ? 'Número incompleto' : null;
              },
            ),
            const SizedBox(height: 14),
            Row(children: [
              Expanded(
                child: TextFormField(
                  controller: _plan,
                  style: const TextStyle(color: C.text),
                  decoration: _dec('Plan'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextFormField(
                  controller: _precio,
                  style: const TextStyle(color: C.text, fontFamily: mono),
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  decoration: _dec('Precio USD'),
                ),
              ),
            ]),
            const SizedBox(height: 14),
            DropdownButtonFormField<int>(
              initialValue: _dia,
              dropdownColor: C.surfaceAlt,
              style: const TextStyle(color: C.text, fontFamily: mono),
              decoration: _dec('Día de pago',
                  ayuda: 'El aviso llega el día anterior. Rango 1 a 28.'),
              items: List.generate(28, (i) => i + 1)
                  .map((d) => DropdownMenuItem(value: d, child: Text('Día $d')))
                  .toList(),
              onChanged: (v) => setState(() => _dia = v ?? 1),
            ),
            const SizedBox(height: 14),
            TextFormField(
              controller: _ip,
              style: const TextStyle(color: C.text, fontFamily: mono),
              decoration: _dec('IP'),
            ),
            const SizedBox(height: 14),
            TextFormField(
              controller: _mac,
              style: const TextStyle(color: C.text, fontFamily: mono),
              textCapitalization: TextCapitalization.characters,
              inputFormatters: [UpperCaseFormatter()],
              decoration: _dec('MAC'),
            ),
            const SizedBox(height: 14),
            TextFormField(
              controller: _notas,
              style: const TextStyle(color: C.text),
              maxLines: 2,
              decoration: _dec('Notas'),
            ),
            const SizedBox(height: 8),
            SwitchListTile(
              value: _activo,
              activeThumbColor: C.up,
              contentPadding: EdgeInsets.zero,
              title: const Text('Cliente activo',
                  style: TextStyle(color: C.text, fontSize: 15)),
              subtitle: const Text('Si lo apagas, deja de recibir avisos',
                  style: TextStyle(color: C.muted, fontSize: 12.5)),
              onChanged: (v) => setState(() => _activo = v),
            ),
            const SizedBox(height: 18),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: C.up,
                foregroundColor: C.bg,
                minimumSize: const Size.fromHeight(48),
              ),
              onPressed: _guardar,
              child: const Text('Guardar cliente',
                  style: TextStyle(fontWeight: FontWeight.w600)),
            ),
          ],
        ),
      ),
    );
  }
}

class UpperCaseFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(TextEditingValue a, TextEditingValue b) =>
      b.copyWith(text: b.text.toUpperCase());
}

// ===========================================================================
// 3. PAGOS
// ===========================================================================
class HistorialPagos extends StatefulWidget {
  const HistorialPagos({super.key});
  @override
  State<HistorialPagos> createState() => _HistorialPagosState();
}

class _HistorialPagosState extends State<HistorialPagos> {
  List<Pago> _pagos = [];
  Map<int, Cliente> _clientes = {};

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  Future<void> _cargar() async {
    final cs = await DB.i.clientes();
    final ps = await DB.i.pagos();
    if (!mounted) return;
    setState(() {
      _clientes = {for (final c in cs) c.id!: c};
      _pagos = ps;
    });
  }

  @override
  Widget build(BuildContext context) {
    final total = _pagos
        .where((p) => p.periodo == periodoActual())
        .fold<double>(0, (s, p) => s + p.monto);

    return ListView(
      padding: const EdgeInsets.fromLTRB(14, 16, 14, 30),
      children: [
        const Text('Pagos',
            style: TextStyle(
                fontSize: 22, fontWeight: FontWeight.w700, color: C.text)),
        Text('${_pagos.length} registrados  ·  '
            '${total.toStringAsFixed(2)} USD este mes',
            style: const TextStyle(fontSize: 12.5, color: C.muted)),
        const SizedBox(height: 18),
        if (_pagos.isEmpty)
          _vacio('Sin pagos registrados',
              'Registra un pago desde el panel cuando un cliente te pague.'),
        ..._pagos.map((p) {
          final c = _clientes[p.clienteId];
          return Container(
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              color: C.surface,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: C.line),
            ),
            child: Row(children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(c?.nombre ?? 'Cliente eliminado',
                        style: const TextStyle(
                            color: C.text,
                            fontSize: 15,
                            fontWeight: FontWeight.w600)),
                    const SizedBox(height: 3),
                    Text('${p.fecha}  ·  periodo ${p.periodo}',
                        style: const TextStyle(
                            color: C.muted, fontSize: 12, fontFamily: mono)),
                  ],
                ),
              ),
              Text('${p.monto.toStringAsFixed(2)}',
                  style: const TextStyle(
                      color: C.up,
                      fontSize: 15,
                      fontFamily: mono,
                      fontWeight: FontWeight.w600)),
              IconButton(
                icon: const Icon(Icons.close, size: 18, color: C.off),
                onPressed: () async {
                  await DB.i.borrarPago(p.id!);
                  _cargar();
                },
              ),
            ]),
          );
        }),
      ],
    );
  }
}

// ===========================================================================
// 4. AJUSTES
// ===========================================================================
class Ajustes extends StatefulWidget {
  const Ajustes({super.key});
  @override
  State<Ajustes> createState() => _AjustesState();
}

class _AjustesState extends State<Ajustes> {
  final _plantilla = TextEditingController();
  int _hora = 9, _minuto = 0;
  bool _listo = false;

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  Future<void> _cargar() async {
    _plantilla.text = await DB.i.leer('plantilla', plantillaPorDefecto);
    _hora = int.parse(await DB.i.leer('hora', '9'));
    _minuto = int.parse(await DB.i.leer('minuto', '0'));
    if (mounted) setState(() => _listo = true);
  }

  Future<void> _guardar() async {
    await DB.i.escribir('plantilla', _plantilla.text.trim());
    await DB.i.escribir('hora', '$_hora');
    await DB.i.escribir('minuto', '$_minuto');
    await Avisos.i.reprogramar();
    if (mounted) {
      aviso(context, 'Avisos reprogramados');
      Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_listo) {
      return const Scaffold(
          backgroundColor: C.bg,
          body: Center(child: CircularProgressIndicator(color: C.up)));
    }
    final hh = _hora.toString().padLeft(2, '0');
    final mm = _minuto.toString().padLeft(2, '0');

    return Scaffold(
      backgroundColor: C.bg,
      appBar: AppBar(
          backgroundColor: C.bg,
          foregroundColor: C.text,
          title: const Text('Ajustes')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(14, 8, 14, 30),
        children: [
          const Text('HORA DEL AVISO',
              style: TextStyle(
                  fontSize: 11.5,
                  letterSpacing: 1.2,
                  fontWeight: FontWeight.w700,
                  color: C.muted)),
          const SizedBox(height: 8),
          InkWell(
            onTap: () async {
              final t = await showTimePicker(
                context: context,
                initialTime: TimeOfDay(hour: _hora, minute: _minuto),
              );
              if (t != null) {
                setState(() {
                  _hora = t.hour;
                  _minuto = t.minute;
                });
              }
            },
            child: Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: C.surface,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: C.line),
              ),
              child: Row(children: [
                const Icon(Icons.schedule, color: C.up, size: 20),
                const SizedBox(width: 12),
                Text('$hh:$mm',
                    style: const TextStyle(
                        color: C.text, fontSize: 20, fontFamily: mono)),
                const Spacer(),
                const Text('Cambiar',
                    style: TextStyle(color: C.muted, fontSize: 13)),
              ]),
            ),
          ),
          const SizedBox(height: 24),
          const Text('MENSAJE DE WHATSAPP',
              style: TextStyle(
                  fontSize: 11.5,
                  letterSpacing: 1.2,
                  fontWeight: FontWeight.w700,
                  color: C.muted)),
          const SizedBox(height: 8),
          TextField(
            controller: _plantilla,
            maxLines: 5,
            style: const TextStyle(color: C.text, fontSize: 14),
            decoration: InputDecoration(
              filled: true,
              fillColor: C.surface,
              helperText:
                  'Etiquetas: {nombre} {dia} {precio} {plan} {ip}',
              helperStyle: const TextStyle(color: C.off, fontSize: 11.5),
              border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: const BorderSide(color: C.line)),
              enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: const BorderSide(color: C.line)),
              focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: const BorderSide(color: C.up)),
            ),
          ),
          const SizedBox(height: 24),
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(
              foregroundColor: C.muted,
              side: const BorderSide(color: C.line),
              minimumSize: const Size.fromHeight(46),
            ),
            icon: const Icon(Icons.notifications_active_outlined, size: 18),
            label: const Text('Probar una notificación ahora'),
            onPressed: () => Avisos.i.prueba(),
          ),
          const SizedBox(height: 12),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: C.up,
              foregroundColor: C.bg,
              minimumSize: const Size.fromHeight(48),
            ),
            onPressed: _guardar,
            child: const Text('Guardar y reprogramar',
                style: TextStyle(fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
  }
}
