import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:intl/intl.dart';

import '../data/store.dart';
import '../design_assets.dart';

const green = Color(0xFF03C75A),
    ink = Color(0xFF191C1D),
    muted = Color(0xFF66727E),
    line = Color(0xFFE2E7EB),
    surface = Color(0xFFF4F6F8);
String number(num v) => NumberFormat.decimalPattern('ko').format(v);
String day(DateTime v) => DateFormat('yyyy.MM.dd').format(v);
String statusLabel(VehicleStatus s) => ['낮음', '관찰', '높음', '미분석'][s.index];
Color statusColor(VehicleStatus s) =>
    [green, const Color(0xFFF59E0B), const Color(0xFFE53935), muted][s.index];

class DesignIcon extends StatelessWidget {
  const DesignIcon(this.node, this.name, {this.size = 20, super.key});
  final String node, name;
  final double size;
  @override
  Widget build(BuildContext context) {
    final path = designAssets[node]?[name];
    if (path == null) return SizedBox(width: size, height: size);
    return SizedBox.square(
      dimension: size,
      child: path.endsWith('.svg')
          ? SvgPicture.asset(path, fit: BoxFit.contain)
          : Image.asset(path, fit: BoxFit.contain),
    );
  }
}

class StatusBadge extends StatelessWidget {
  const StatusBadge(this.status, {super.key});
  final VehicleStatus status;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
    decoration: BoxDecoration(
      color: statusColor(status).withValues(alpha: .06),
      border: Border.all(color: statusColor(status).withValues(alpha: .3)),
      borderRadius: BorderRadius.circular(5),
    ),
    child: Text(
      '● ${statusLabel(status)}',
      style: TextStyle(
        color: statusColor(status),
        fontSize: 11,
        fontWeight: FontWeight.w700,
      ),
    ),
  );
}

class Panel extends StatelessWidget {
  const Panel({
    required this.title,
    required this.child,
    this.subtitle,
    this.action,
    this.padding = 18,
    super.key,
  });
  final String title;
  final String? subtitle;
  final Widget child;
  final Widget? action;
  final double padding;
  @override
  Widget build(BuildContext context) => Container(
    decoration: BoxDecoration(
      color: Colors.white,
      border: Border.all(color: line),
      borderRadius: BorderRadius.circular(12),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: EdgeInsets.all(padding),
          child: Row(
            children: [
              Container(width: 3, height: 19, color: green),
              const SizedBox(width: 9),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    if (subtitle != null)
                      Text(
                        subtitle!,
                        style: const TextStyle(fontSize: 11, color: muted),
                      ),
                  ],
                ),
              ),
              ?action,
            ],
          ),
        ),
        const Divider(height: 1, color: line),
        Padding(
          padding: EdgeInsets.all(padding),
          child: Material(type: MaterialType.transparency, child: child),
        ),
      ],
    ),
  );
}

class DataScopeNotice extends StatelessWidget {
  const DataScopeNotice(this.vehicles, {this.label = '조회 대상', super.key});
  final Iterable<Vehicle> vehicles;
  final String label;

  @override
  Widget build(BuildContext context) {
    final ids = vehicles.map((v) => v.id).toSet();
    final examples = ids.where((id) => id.startsWith('MOCK-')).length;
    final registered = ids.length - examples;
    final scope = ids.isEmpty
        ? '차량 없음'
        : examples == 0
        ? '등록 차량 $registered대 · 합성 고장확률 미적용'
        : registered == 0
        ? '예제 차량 $examples대 · 실사용 자료와 구분'
        : '등록 차량 $registered대 · 예제 차량 $examples대 혼합';
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: (examples == 0 ? green : Colors.orange).withValues(alpha: .08),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(
          '$label: $scope',
          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
        ),
      ),
    );
  }
}

class PageTitle extends StatelessWidget {
  const PageTitle(
    this.title,
    this.description, {
    this.action,
    this.scopeVehicles,
    this.scopeLabel = '조회 대상',
    super.key,
  });
  final String title, description;
  final Widget? action;
  final Iterable<Vehicle>? scopeVehicles;
  final String scopeLabel;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 18),
    child: Column(
      children: [
        Row(
          children: [
            Container(width: 3, height: 25, color: green),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                title,
                style: const TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
            ?action,
          ],
        ),
        const SizedBox(height: 5),
        Align(
          alignment: Alignment.centerLeft,
          child: Text(
            description,
            style: const TextStyle(fontSize: 12, color: muted),
          ),
        ),
        if (scopeVehicles != null) ...[
          const SizedBox(height: 8),
          DataScopeNotice(scopeVehicles!, label: scopeLabel),
        ],
        const SizedBox(height: 12),
        const Divider(height: 1, color: line),
      ],
    ),
  );
}

class ResponsiveColumns extends StatelessWidget {
  const ResponsiveColumns({
    required this.children,
    this.breakpoint = 900,
    this.flexes,
    super.key,
  });
  final List<Widget> children;
  final double breakpoint;
  final List<int>? flexes;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, c) => c.maxWidth >= breakpoint
        ? Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (var i = 0; i < children.length; i++) ...[
                if (i > 0) const SizedBox(width: 14),
                Expanded(flex: flexes?[i] ?? 1, child: children[i]),
              ],
            ],
          )
        : Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var i = 0; i < children.length; i++) ...[
                if (i > 0) const SizedBox(height: 14),
                children[i],
              ],
            ],
          ),
  );
}

class SummaryCards extends StatelessWidget {
  const SummaryCards(this.vehicles, {super.key});
  final List<Vehicle> vehicles;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, c) {
      final cols = c.maxWidth < 600 ? 2 : 4;
      return Wrap(
        spacing: 12,
        runSpacing: 12,
        children: List.generate(4, (i) {
          final total = i == 0,
              count = total
                  ? vehicles.length
                  : vehicles.where((v) => v.status.index == i - 1).length;
          final color = total ? ink : statusColor(VehicleStatus.values[i - 1]);
          return Container(
            width: (c.maxWidth - (cols - 1) * 12) / cols,
            padding: const EdgeInsets.all(17),
            decoration: BoxDecoration(
              color: total
                  ? ink
                  : i == 3
                  ? const Color(0xFFFFF1F1)
                  : Colors.white,
              border: Border.all(
                color: i == 3 ? const Color(0xFFFFC8C6) : line,
              ),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '● ${['전체 차량', '낮음', '관찰', '높음'][i]}',
                  style: TextStyle(
                    color: total ? Colors.white70 : color,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  '$count대',
                  style: TextStyle(
                    fontSize: 30,
                    fontWeight: FontWeight.w800,
                    color: total ? Colors.white : ink,
                  ),
                ),
                Text(
                  total
                      ? '미분석 ${vehicles.where((v) => !v.predictionReady).length}대 포함'
                      : i == 3
                      ? '목업 추정치 분류'
                      : '전체의 ${vehicles.isEmpty ? 0 : (count / vehicles.length * 100).round()}%',
                  style: TextStyle(
                    fontSize: 11,
                    color: total ? Colors.white54 : color,
                  ),
                ),
              ],
            ),
          );
        }),
      );
    },
  );
}

class DataGrid extends StatelessWidget {
  const DataGrid({
    required this.columns,
    required this.rows,
    this.minWidth = 680,
    super.key,
  });
  final List<String> columns;
  final List<List<Widget>> rows;
  final double minWidth;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, c) => SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: SizedBox(
        width: math.max(c.maxWidth, minWidth),
        child: DataTable(
          headingRowColor: const WidgetStatePropertyAll(Color(0xFFF8F9FA)),
          headingRowHeight: 42,
          dataRowMinHeight: 52,
          dataRowMaxHeight: 66,
          columnSpacing: 18,
          horizontalMargin: 12,
          border: const TableBorder(horizontalInside: BorderSide(color: line)),
          columns: columns
              .map(
                (s) => DataColumn(
                  label: Text(
                    s,
                    style: const TextStyle(
                      color: muted,
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              )
              .toList(),
          rows: rows
              .map(
                (cells) =>
                    DataRow(cells: cells.map((w) => DataCell(w)).toList()),
              )
              .toList(),
        ),
      ),
    ),
  );
}

Widget cell(String text, {bool bold = false, Color? color}) => Text(
  text,
  style: TextStyle(
    fontSize: 12,
    fontWeight: bold ? FontWeight.w700 : FontWeight.w400,
    color: color ?? ink,
  ),
);
Widget empty(String message) => Padding(
  padding: const EdgeInsets.symmetric(vertical: 36),
  child: Center(
    child: Text(message, style: const TextStyle(color: muted)),
  ),
);
Widget note(String message, {Color color = green}) => Container(
  width: double.infinity,
  padding: const EdgeInsets.all(13),
  decoration: BoxDecoration(
    color: color.withValues(alpha: .06),
    borderRadius: BorderRadius.circular(6),
    border: Border(left: BorderSide(color: color, width: 3)),
  ),
  child: Text(
    message,
    style: TextStyle(fontSize: 12, color: color == green ? muted : color),
  ),
);

class Bars extends StatelessWidget {
  const Bars(this.values, {super.key});
  final Map<String, num> values;
  @override
  Widget build(BuildContext context) {
    final max = values.values.fold<num>(1, (a, b) => math.max(a, b));
    return Column(
      children: values.entries
          .map(
            (e) => Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Row(
                children: [
                  SizedBox(
                    width: 90,
                    child: cell(e.key, bold: true, color: muted),
                  ),
                  Expanded(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: LinearProgressIndicator(
                        value: e.value / max,
                        minHeight: 10,
                        color: green,
                        backgroundColor: surface,
                      ),
                    ),
                  ),
                  const SizedBox(width: 14),
                  SizedBox(
                    width: 34,
                    child: cell(number(e.value), bold: true, color: green),
                  ),
                ],
              ),
            ),
          )
          .toList(),
    );
  }
}

class StatusRing extends StatelessWidget {
  const StatusRing(this.vehicles, {super.key});
  final List<Vehicle> vehicles;
  @override
  Widget build(BuildContext context) => SizedBox(
    height: 220,
    child: Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        SizedBox.square(
          dimension: 160,
          child: Stack(
            alignment: Alignment.center,
            children: [
              CustomPaint(
                size: const Size.square(160),
                painter: _RingPainter(vehicles),
              ),
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '${vehicles.length}대',
                    style: const TextStyle(
                      fontSize: 26,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const Text(
                    '전체 차량',
                    style: TextStyle(color: muted, fontSize: 11),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(width: 22),
        Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: VehicleStatus.values
              .map(
                (s) => Padding(
                  padding: const EdgeInsets.symmetric(vertical: 7),
                  child: Text(
                    '● ${statusLabel(s)}  ${vehicles.where((v) => v.status == s).length}대',
                    style: TextStyle(color: statusColor(s), fontSize: 12),
                  ),
                ),
              )
              .toList(),
        ),
      ],
    ),
  );
}

class _RingPainter extends CustomPainter {
  _RingPainter(this.vehicles);
  final List<Vehicle> vehicles;
  @override
  void paint(Canvas canvas, Size size) {
    final statuses = [...vehicles]
      ..sort((a, b) => a.status.index.compareTo(b.status.index));
    for (var i = 0; i < 60; i++) {
      final a = -math.pi / 2 + i * math.pi * 2 / 60;
      final s = statuses.isEmpty
          ? VehicleStatus.normal
          : statuses[(i / 60 * statuses.length).floor()].status;
      canvas.drawCircle(
        Offset(
          size.width / 2 + 66 * math.cos(a),
          size.height / 2 + 66 * math.sin(a),
        ),
        3.5,
        Paint()..color = statusColor(s),
      );
    }
  }

  @override
  bool shouldRepaint(_RingPainter old) => true;
}
