import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'biometric_export.dart';
import 'biometric_testing.dart';
import 'storage.dart';

class BiometricTestingScreen extends StatefulWidget {
  const BiometricTestingScreen({
    super.key,
    required this.store,
    required this.onRunTrial,
    this.dataShare = const AndroidBiometricDataShare(),
  });

  final BiometricRecordStore store;
  final Future<BiometricTrialRecord?> Function(BiometricTrialSetup setup)
  onRunTrial;
  final BiometricDataShare dataShare;

  @override
  State<BiometricTestingScreen> createState() => _BiometricTestingScreenState();
}

class _BiometricTestingScreenState extends State<BiometricTestingScreen> {
  final _enrolledId = TextEditingController();
  final _probeId = TextEditingController();
  final _deviceLabel = TextEditingController();
  BiometricLightingCondition _condition =
      BiometricLightingCondition.indoorNormal;
  List<BiometricTrialRecord> _records = const [];
  String _message = '';
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final records = await widget.store.readBiometricRecords();
    if (mounted) setState(() => _records = records);
  }

  Future<void> _runTrial() async {
    if (_busy) return;
    BiometricTrialSetup setup;
    try {
      setup = BiometricTrialSetup(
        enrolledId: _enrolledId.text,
        probeId: _probeId.text,
        condition: _condition,
        deviceLabel: _deviceLabel.text,
      );
    } on FormatException catch (error) {
      setState(() => _message = error.message);
      return;
    }
    setState(() {
      _busy = true;
      _message = '';
    });
    try {
      final record = await widget.onRunTrial(setup);
      if (record != null) {
        await widget.store.appendBiometricRecord(record);
        await _refresh();
        if (mounted) {
          setState(
            () => _message = record.failureReason == null
                ? 'Trial recorded.'
                : 'Excluded trial recorded with its failure reason.',
          );
        }
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _export() async {
    if (_busy || _records.isEmpty) return;
    setState(() => _busy = true);
    try {
      await widget.dataShare.share(_records);
      if (mounted) setState(() => _message = 'Android sharing opened.');
    } catch (_) {
      if (mounted) setState(() => _message = 'Could not export test data.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _confirmClear() async {
    if (_busy || _records.isEmpty) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear biometric test data?'),
        content: const Text(
          'This permanently removes every locally recorded research trial. '
          'Export first if the data is still needed.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const Key('confirm_clear_biometric_data'),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Clear'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await widget.dataShare.clearExports();
    await widget.store.clearBiometricRecords();
    await _refresh();
    if (mounted) setState(() => _message = 'Biometric test data cleared.');
  }

  @override
  Widget build(BuildContext context) {
    if (!kDebugMode) {
      return const Scaffold(body: Center(child: Text('Testing unavailable.')));
    }
    return Scaffold(
      appBar: AppBar(title: const Text('Biometric Testing Mode')),
      body: ListView(
        padding: const EdgeInsets.all(18),
        children: [
          const Card(
            child: Padding(
              padding: EdgeInsets.all(16),
              child: Text(
                'Controlled prototype research only. Use pseudonymous IDs. '
                'Do not enter names or begin participant testing until consent '
                'and privacy procedures are approved.',
              ),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const Key('biometric_enrolled_id'),
            controller: _enrolledId,
            textCapitalization: TextCapitalization.characters,
            decoration: const InputDecoration(
              labelText: 'Enrolled participant ID',
              hintText: 'P01',
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const Key('biometric_probe_id'),
            controller: _probeId,
            textCapitalization: TextCapitalization.characters,
            decoration: const InputDecoration(
              labelText: 'Probe participant ID',
              hintText: 'P02',
            ),
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<BiometricLightingCondition>(
            key: const Key('biometric_condition'),
            initialValue: _condition,
            decoration: const InputDecoration(labelText: 'Lighting condition'),
            items: BiometricLightingCondition.values
                .map(
                  (condition) => DropdownMenuItem(
                    value: condition,
                    child: Text(condition.displayLabel),
                  ),
                )
                .toList(),
            onChanged: _busy
                ? null
                : (value) => setState(() => _condition = value!),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const Key('biometric_device_label'),
            controller: _deviceLabel,
            maxLength: 64,
            decoration: const InputDecoration(
              labelText: 'Device model or code (optional)',
              hintText: 'OPPO CPH2371',
            ),
          ),
          const SizedBox(height: 8),
          FilledButton.icon(
            key: const Key('run_biometric_trial'),
            onPressed: _busy ? null : _runTrial,
            icon: const Icon(Icons.face_retouching_natural),
            label: const Text('Run Biometric Trial'),
          ),
          const SizedBox(height: 20),
          Text(
            '${_records.length} trial${_records.length == 1 ? '' : 's'} stored locally',
            key: const Key('biometric_record_count'),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            key: const Key('export_biometric_data'),
            onPressed: _busy || _records.isEmpty ? null : _export,
            icon: const Icon(Icons.ios_share),
            label: const Text('Export Biometric Test Data'),
          ),
          TextButton.icon(
            key: const Key('clear_biometric_data'),
            onPressed: _busy || _records.isEmpty ? null : _confirmClear,
            icon: const Icon(Icons.delete_outline),
            label: const Text('Clear Biometric Test Data'),
          ),
          if (_message.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(_message, key: const Key('biometric_testing_message')),
          ],
        ],
      ),
    );
  }

  @override
  void dispose() {
    _enrolledId.dispose();
    _probeId.dispose();
    _deviceLabel.dispose();
    super.dispose();
  }
}
