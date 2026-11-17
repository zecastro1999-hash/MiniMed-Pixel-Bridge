import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../main.dart';
import '../models/pump_telemetry.dart';
import '../services/carelink_service.dart';
import '../services/notification_service.dart';

Future<void> showTargetRangeSheet({
  required BuildContext context,
  required TargetRangeConfig currentRange,
  required Future<void> Function(TargetRangeConfig newRange) onSaved,
}) async {
  int low = currentRange.lowMgDl;
  int high = currentRange.highMgDl;

  await showModalBottomSheet<void>(
    context: context,
    backgroundColor: EspressoPalette.cardEspresso,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
    ),
    builder: (ctx) {
      return StatefulBuilder(
        builder: (ctx, setModalState) {
          return Padding(
            padding: const EdgeInsets.fromLTRB(22, 22, 22, 28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Intervalo-alvo de glicose',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    color: EspressoPalette.creamText,
                  ),
                ),
                const SizedBox(height: 6),
                const Text(
                  'Personaliza os limites do Tempo no alvo (predefinição clínica: 70–180 mg/dL, inclusive).',
                  style: TextStyle(
                    fontSize: 12.5,
                    color: EspressoPalette.sandAccent,
                  ),
                ),
                const SizedBox(height: 20),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
                      'Limite inferior',
                      style: TextStyle(
                        color: EspressoPalette.creamText,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Text(
                      '$low mg/dL',
                      style: const TextStyle(
                        color: EspressoPalette.peachAccent,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
                Slider(
                  value: low.toDouble(),
                  min: 55,
                  max: 110,
                  divisions: 11,
                  activeColor: EspressoPalette.peachAccent,
                  onChanged: (v) {
                    setModalState(() {
                      low = v.round();
                      if (high < low + 25) {
                        high = low + 25;
                      }
                    });
                  },
                ),
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
                      'Limite superior',
                      style: TextStyle(
                        color: EspressoPalette.creamText,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Text(
                      '$high mg/dL',
                      style: const TextStyle(
                        color: EspressoPalette.peachAccent,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
                Slider(
                  value: high.toDouble(),
                  min: 120,
                  max: 250,
                  divisions: 26,
                  activeColor: EspressoPalette.peachAccent,
                  onChanged: (v) {
                    setModalState(() {
                      high = v.round();
                      if (high < low + 25) {
                        high = low + 25;
                      }
                    });
                  },
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    TextButton(
                      onPressed: () {
                        setModalState(() {
                          low = 70;
                          high = 180;
                        });
                      },
                      child: const Text(
                        'Repor 70–180',
                        style: TextStyle(color: EspressoPalette.sandAccent),
                      ),
                    ),
                    const Spacer(),
                    FilledButton(
                      style: FilledButton.styleFrom(
                        backgroundColor: EspressoPalette.peachAccent,
                        foregroundColor: EspressoPalette.darkPillText,
                      ),
                      onPressed: () async {
                        await onSaved(
                          TargetRangeConfig(lowMgDl: low, highMgDl: high)
                              .sanitized(),
                        );
                        if (ctx.mounted) Navigator.of(ctx).pop();
                      },
                      child: const Text('Guardar'),
                    ),
                  ],
                ),
              ],
            ),
          );
        },
      );
    },
  );
}

String _formatClockDatePt(DateTime dt) {
  final local = dt.toLocal();
  final hh = local.hour.toString().padLeft(2, '0');
  final mm = local.minute.toString().padLeft(2, '0');
  final dd = local.day.toString().padLeft(2, '0');
  final mo = local.month.toString().padLeft(2, '0');
  return '$dd/$mo $hh:$mm';
}

Future<void> showCareLinkSourceSheet({
  required BuildContext context,
  required CareLinkService careLinkService,
  required NotificationService notificationService,
  required Future<void> Function() onUpdated,
}) async {
  final prefs = await SharedPreferences.getInstance();
  CareLinkTokenBundle? existingBundle =
      await careLinkService.loadStoredTokenBundle();
  CareLinkRefreshDiagnostics refreshDiag =
      await careLinkService.inspectStoredRefresh();

  bool useXdrip = prefs.getBool(CareLinkService.prefKeyUseXdrip) ?? false;
  final usernameCtrl = TextEditingController(
    text: prefs.getString(CareLinkService.prefKeyUsername) ??
        existingBundle?.username ??
        '',
  );
  final patientIdCtrl = TextEditingController(
    text: prefs.getString(CareLinkService.prefKeyPatientId) ?? '',
  );
  // Security: NEVER pre-fill existing raw secret/JWT tokens in the input field.
  final importCtrl = TextEditingController();
  final xdripUrlCtrl = TextEditingController(
    text: prefs.getString(CareLinkService.prefKeyXdripUrl) ??
        CareLinkService.defaultXdripUrl,
  );

  String? modalError;
  bool isTesting = false;
  bool isTestingRefresh = false;
  String? pendingRawImport;
  CareLinkTokenBundle? pendingParsed;

  if (!context.mounted) return;

  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: EspressoPalette.cardEspresso,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
    ),
    builder: (ctx) {
      return StatefulBuilder(
        builder: (ctx, setModalState) {
          void applyImportedText(String raw, {bool syncTextField = false}) {
            final cleaned = raw.replaceFirst('\uFEFF', '').trim();
            final parsed = CareLinkService.parseLoginDataOrToken(cleaned);
            setModalState(() {
              pendingRawImport = cleaned;
              pendingParsed = parsed;
              if (syncTextField) {
                importCtrl.text = cleaned;
              } else {
                // Keep raw secret out of editable widget state when imported via file/clipboard.
                importCtrl.clear();
              }
              if (parsed?.username != null &&
                  parsed!.username!.isNotEmpty &&
                  usernameCtrl.text.trim().isEmpty) {
                usernameCtrl.text = parsed.username!;
              }
              modalError = parsed == null
                  ? 'Não foi possível ler credenciais CareLink válidas do conteúdo importado.'
                  : null;
            });
          }

          Future<void> handleTestRefresh() async {
            if (isTestingRefresh || isTesting) return;
            setModalState(() {
              isTestingRefresh = true;
              modalError = null;
            });

            final diag = await careLinkService.testRefresh();
            final updatedBundle = await careLinkService.loadStoredTokenBundle();
            if (!ctx.mounted) return;
            setModalState(() {
              refreshDiag = diag;
              existingBundle = updatedBundle;
              isTestingRefresh = false;
            });
            if (diag.isVerified) {
              await onUpdated();
            }
          }

          final pendingDiag = pendingParsed == null
              ? null
              : CareLinkService.inspectBundleRefresh(pendingParsed);

          return Padding(
            padding: EdgeInsets.only(
              left: 20,
              right: 20,
              top: 22,
              bottom: MediaQuery.of(ctx).viewInsets.bottom + 24,
            ),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Fonte CareLink & xDrip+',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                      color: EspressoPalette.creamText,
                    ),
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    'As credenciais OAuth2 ficam cifradas no Keystore Android e a sessão renova automaticamente enquanto autorizada.',
                    style: TextStyle(
                      fontSize: 12,
                      color: EspressoPalette.sandAccent,
                    ),
                  ),
                  const SizedBox(height: 12),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    activeThumbColor: EspressoPalette.peachAccent,
                    title: const Text(
                      'Usar xDrip+ local',
                      style: TextStyle(
                        color: EspressoPalette.creamText,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    subtitle: const Text(
                      'Endpoint local http://127.0.0.1:17580/sgv.json',
                      style: TextStyle(
                        color: EspressoPalette.sandAccent,
                        fontSize: 12,
                      ),
                    ),
                    value: useXdrip,
                    onChanged: (val) => setModalState(() {
                      useXdrip = val;
                      modalError = null;
                    }),
                  ),
                  const SizedBox(height: 10),
                  if (useXdrip)
                    TextField(
                      controller: xdripUrlCtrl,
                      style: const TextStyle(color: EspressoPalette.creamText),
                      decoration: const InputDecoration(
                        labelText: 'URL local xDrip+',
                        border: OutlineInputBorder(),
                      ),
                    )
                  else ...[
                    if (existingBundle != null) ...[
                      Container(
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: EspressoPalette.cardBrown,
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Icon(
                                  existingBundle!.reauthRequired
                                      ? Icons.lock_reset_rounded
                                      : refreshDiag.isVerified
                                          ? Icons.verified_user_rounded
                                          : Icons.shield_outlined,
                                  color: existingBundle!.reauthRequired ||
                                          refreshDiag.readiness ==
                                              CareLinkRefreshReadiness.failed
                                      ? const Color(0xFFFFB4AB)
                                      : EspressoPalette.peachAccent,
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        existingBundle!.reauthRequired
                                            ? 'Necessária nova autenticação'
                                            : 'Sessão guardada de forma segura',
                                        style: const TextStyle(
                                          color: EspressoPalette.creamText,
                                          fontWeight: FontWeight.w700,
                                          fontSize: 13,
                                        ),
                                      ),
                                      const SizedBox(height: 2),
                                      Text(
                                        '${existingBundle!.username != null ? "Conta: ${existingBundle!.username} · " : ""}Renovação: ${refreshDiag.summaryPt}',
                                        style: TextStyle(
                                          color: refreshDiag.readiness ==
                                                      CareLinkRefreshReadiness
                                                          .incomplete ||
                                                  refreshDiag.readiness ==
                                                      CareLinkRefreshReadiness
                                                          .failed
                                              ? const Color(0xFFFFDAD6)
                                              : EspressoPalette.sandAccent,
                                          fontSize: 11.5,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                IconButton(
                                  tooltip: 'Terminar sessão CareLink',
                                  onPressed: () async {
                                    await careLinkService.clearCredentials();
                                    setModalState(() {
                                      existingBundle = null;
                                      pendingRawImport = null;
                                      pendingParsed = null;
                                      importCtrl.clear();
                                    });
                                    await onUpdated();
                                    if (ctx.mounted) Navigator.of(ctx).pop();
                                  },
                                  icon: const Icon(
                                    Icons.logout_rounded,
                                    color: Color(0xFFFFB4AB),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            Wrap(
                              spacing: 6,
                              runSpacing: 6,
                              children: [
                                for (final p in refreshDiag.presentFields)
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 8,
                                      vertical: 3,
                                    ),
                                    decoration: BoxDecoration(
                                      color: EspressoPalette.cardEspresso,
                                      borderRadius: BorderRadius.circular(10),
                                    ),
                                    child: Text(
                                      '$p ✓',
                                      style: const TextStyle(
                                        color: EspressoPalette.peachAccent,
                                        fontSize: 10.5,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ),
                                for (final m in refreshDiag.missingFields)
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 8,
                                      vertical: 3,
                                    ),
                                    decoration: BoxDecoration(
                                      color: const Color(0xFF3E1E19),
                                      borderRadius: BorderRadius.circular(10),
                                    ),
                                    child: Text(
                                      '$m ✗',
                                      style: const TextStyle(
                                        color: Color(0xFFFFB4AB),
                                        fontSize: 10.5,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                            const SizedBox(height: 6),
                            Text(
                              refreshDiag.lastVerifiedAt != null &&
                                      refreshDiag.isVerified
                                  ? '${refreshDiag.detailPt} (${_formatClockDatePt(refreshDiag.lastVerifiedAt!)})'
                                  : refreshDiag.detailPt,
                              style: const TextStyle(
                                color: EspressoPalette.creamText,
                                fontSize: 11,
                              ),
                            ),
                            if (refreshDiag.preservedActiveSession) ...[
                              const SizedBox(height: 4),
                              const Text(
                                'A sessão atual continua funcional até o access_token expirar.',
                                style: TextStyle(
                                  color: EspressoPalette.sandAccent,
                                  fontSize: 10.5,
                                ),
                              ),
                            ],
                            const SizedBox(height: 10),
                            SizedBox(
                              width: double.infinity,
                              child: OutlinedButton.icon(
                                style: OutlinedButton.styleFrom(
                                  foregroundColor: EspressoPalette.peachAccent,
                                  side: const BorderSide(
                                    color: EspressoPalette.sandAccent,
                                  ),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(16),
                                  ),
                                ),
                                onPressed: isTestingRefresh || isTesting
                                    ? null
                                    : handleTestRefresh,
                                icon: isTestingRefresh
                                    ? const SizedBox(
                                        width: 14,
                                        height: 14,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                          color: EspressoPalette.peachAccent,
                                        ),
                                      )
                                    : const Icon(
                                        Icons.refresh_rounded,
                                        size: 16,
                                      ),
                                label: Text(
                                  isTestingRefresh
                                      ? 'A testar renovação...'
                                      : 'Testar renovação',
                                  style: const TextStyle(
                                    fontSize: 12.5,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 12),
                    ],
                    Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: EspressoPalette.cardBrown.withValues(alpha: 0.72),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            existingBundle == null
                                ? 'Importar logindata.json'
                                : 'Substituir / Renovar manualmente (logindata.json)',
                            style: const TextStyle(
                              color: EspressoPalette.peachAccent,
                              fontWeight: FontWeight.w700,
                              fontSize: 13,
                            ),
                          ),
                          const SizedBox(height: 4),
                          const Text(
                            'Autenticação inicial gerada por carelink_carepartner_api_login.py. Os tokens são armazenados apenas no armazenamento encriptado Android.',
                            style: TextStyle(
                              color: EspressoPalette.creamText,
                              fontSize: 11.5,
                            ),
                          ),
                          const SizedBox(height: 10),
                          Row(
                            children: [
                              Expanded(
                                child: FilledButton.tonalIcon(
                                  style: FilledButton.styleFrom(
                                    backgroundColor:
                                        EspressoPalette.lightCreamPill,
                                    foregroundColor:
                                        EspressoPalette.darkPillText,
                                  ),
                                  onPressed: () async {
                                    final clip =
                                        await Clipboard.getData('text/plain');
                                    final text = clip?.text ?? '';
                                    if (text.trim().isNotEmpty) {
                                      applyImportedText(text);
                                    } else {
                                      setModalState(() {
                                        modalError =
                                            'A área de transferência está vazia.';
                                      });
                                    }
                                  },
                                  icon: const Icon(Icons.content_paste, size: 16),
                                  label: const Text('Colar JSON',
                                      style: TextStyle(fontSize: 12)),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: FilledButton.tonalIcon(
                                  style: FilledButton.styleFrom(
                                    backgroundColor:
                                        EspressoPalette.peachAccent,
                                    foregroundColor:
                                        EspressoPalette.darkPillText,
                                  ),
                                  onPressed: () async {
                                    var content = await notificationService
                                        .tryLoadDownloadLoginData();
                                    content ??= await notificationService
                                        .pickLoginDataFile();
                                    if (content != null &&
                                        content.trim().isNotEmpty) {
                                      applyImportedText(content);
                                    } else {
                                      setModalState(() {
                                        modalError =
                                            'Nenhum ficheiro selecionado.';
                                      });
                                    }
                                  },
                                  icon: const Icon(Icons.file_open_outlined,
                                      size: 16),
                                  label: const Text('Ficheiro',
                                      style: TextStyle(fontSize: 12)),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: importCtrl,
                      obscureText: true,
                      maxLines: 1,
                      onChanged: (val) => applyImportedText(
                        val,
                        syncTextField: true,
                      ),
                      style: const TextStyle(
                        color: EspressoPalette.creamText,
                        fontSize: 13,
                      ),
                      decoration: const InputDecoration(
                        labelText: 'Colar logindata.json manualmente (oculto)',
                        hintText: 'Opcional se usares Ficheiro ou Colar JSON acima',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    if (pendingParsed != null && pendingDiag != null) ...[
                      const SizedBox(height: 6),
                      Text(
                        'Pronto para guardar • Utilizador: ${pendingParsed!.username ?? "--"} • Renovação: ${pendingDiag.summaryPt}',
                        style: TextStyle(
                          fontSize: 11.5,
                          color: pendingDiag.missingFields.isEmpty
                              ? EspressoPalette.peachAccent
                              : const Color(0xFFFFDAD6),
                        ),
                      ),
                    ],
                    const SizedBox(height: 12),
                    TextField(
                      controller: usernameCtrl,
                      style: const TextStyle(color: EspressoPalette.creamText),
                      decoration: const InputDecoration(
                        labelText: 'Utilizador CareLink EU',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: patientIdCtrl,
                      style: const TextStyle(color: EspressoPalette.creamText),
                      decoration: const InputDecoration(
                        labelText: 'ID do paciente (opcional para CarePartner)',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ],
                  if (modalError != null) ...[
                    const SizedBox(height: 12),
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: const Color(0xFF3E1E19),
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Text(
                        modalError!,
                        style: const TextStyle(
                          color: Color(0xFFFFDAD6),
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(height: 18),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      style: FilledButton.styleFrom(
                        backgroundColor: EspressoPalette.peachAccent,
                        foregroundColor: EspressoPalette.darkPillText,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(20),
                        ),
                      ),
                      onPressed: isTesting
                          ? null
                          : () async {
                              setModalState(() {
                                isTesting = true;
                                modalError = null;
                              });

                              try {
                                await prefs.setBool(
                                  CareLinkService.prefKeyUseXdrip,
                                  useXdrip,
                                );
                                await prefs.setString(
                                  CareLinkService.prefKeyXdripUrl,
                                  xdripUrlCtrl.text.trim(),
                                );
                                await prefs.setString(
                                  CareLinkService.prefKeyUsername,
                                  usernameCtrl.text.trim(),
                                );
                                await prefs.setString(
                                  CareLinkService.prefKeyPatientId,
                                  patientIdCtrl.text.trim(),
                                );

                                final newRaw = (pendingRawImport ??
                                        importCtrl.text)
                                    .trim();
                                if (!useXdrip && newRaw.isNotEmpty) {
                                  await careLinkService.saveRawLoginData(
                                    newRaw,
                                    usernameOverride: usernameCtrl.text.trim(),
                                  );
                                }

                                final hasSession =
                                    await careLinkService.loadStoredTokenBundle() !=
                                        null;
                                if (useXdrip || hasSession) {
                                  await careLinkService.fetchLatestTelemetry(
                                    throwOnError: true,
                                  );
                                }
                                await onUpdated();
                                if (ctx.mounted) Navigator.of(ctx).pop();
                              } catch (e) {
                                setModalState(() {
                                  isTesting = false;
                                  modalError = CareLinkService.sanitizeErrorText(
                                    e.toString(),
                                  );
                                });
                              }
                            },
                      child: Text(
                        isTesting
                            ? 'A validar ligação...'
                            : 'Guardar e testar ligação',
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      );
    },
  );
}
