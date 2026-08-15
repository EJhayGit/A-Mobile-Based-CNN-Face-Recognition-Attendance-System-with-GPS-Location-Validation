import 'package:flutter/material.dart';

import 'domain.dart';
import 'queue.dart';

const driverFleetNavy = Color(0xff202637);
const driverFleetNavyDeep = Color(0xff151b29);
const driverFleetBlue = Color(0xff2878f0);
const driverFleetSuccess = Color(0xff20a66a);
const driverFleetWarning = Color(0xffe8a91f);

class FleetLoadingView extends StatelessWidget {
  const FleetLoadingView({super.key});

  @override
  Widget build(BuildContext context) => const Scaffold(
    backgroundColor: driverFleetNavy,
    body: SafeArea(
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            FleetBrand(showName: true),
            SizedBox(height: 28),
            SizedBox(
              width: 28,
              height: 28,
              child: CircularProgressIndicator(
                color: Colors.white,
                strokeWidth: 3,
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class FleetBrand extends StatelessWidget {
  const FleetBrand({super.key, this.showName = false});

  final bool showName;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      ClipRRect(
        borderRadius: BorderRadius.circular(13),
        child: Image.asset(
          'assets/branding/agila_logo.png',
          width: 48,
          height: 48,
          fit: BoxFit.cover,
        ),
      ),
      if (showName) ...[
        const SizedBox(width: 12),
        const Text(
          'AGILA',
          style: TextStyle(
            color: Colors.white,
            fontSize: 18,
            fontWeight: FontWeight.w800,
          ),
        ),
      ],
    ],
  );
}

class AuthView extends StatefulWidget {
  const AuthView({
    super.key,
    required this.busy,
    required this.message,
    required this.endpointController,
    required this.employeeIdController,
    required this.passwordController,
    required this.activationCodeController,
    required this.confirmationController,
    required this.onLogin,
    required this.onActivate,
  });

  final bool busy;
  final String message;
  final TextEditingController endpointController;
  final TextEditingController employeeIdController;
  final TextEditingController passwordController;
  final TextEditingController activationCodeController;
  final TextEditingController confirmationController;
  final VoidCallback onLogin;
  final VoidCallback onActivate;

  @override
  State<AuthView> createState() => _AuthViewState();
}

class _AuthViewState extends State<AuthView> {
  bool _activating = false;
  bool _passwordVisible = false;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: ListView(
      padding: EdgeInsets.zero,
      children: [
        Container(
          constraints: const BoxConstraints(minHeight: 245),
          padding: const EdgeInsets.fromLTRB(24, 52, 24, 64),
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [driverFleetNavyDeep, Color(0xff1b559d)],
            ),
          ),
          child: SafeArea(
            bottom: false,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const FleetBrand(showName: true),
                const SizedBox(height: 30),
                Text(
                  _activating ? 'Join your fleet' : 'Welcome back',
                  style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                    color: Colors.white,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -.8,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  _activating
                      ? 'Activate your secure Driver account to get started.'
                      : 'Your delivery, attendance, and offline records in one place.',
                  style: const TextStyle(
                    color: Color(0xffdbe9ff),
                    height: 1.45,
                  ),
                ),
              ],
            ),
          ),
        ),
        Transform.translate(
          offset: const Offset(0, -34),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: Card(
                margin: const EdgeInsets.symmetric(horizontal: 18),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 22, 20, 18),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: _AuthModeButton(
                              label: 'Sign in',
                              selected: !_activating,
                              onPressed: widget.busy
                                  ? null
                                  : () => setState(() => _activating = false),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: _AuthModeButton(
                              key: const Key('toggle_activation'),
                              label: 'Activate',
                              selected: _activating,
                              onPressed: widget.busy
                                  ? null
                                  : () => setState(() => _activating = true),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 22),
                      TextField(
                        key: const Key('employee_id'),
                        controller: widget.employeeIdController,
                        textCapitalization: TextCapitalization.characters,
                        textInputAction: TextInputAction.next,
                        decoration: const InputDecoration(
                          labelText: 'Employee ID',
                          prefixIcon: Icon(Icons.badge_outlined),
                        ),
                      ),
                      if (_activating) ...[
                        const SizedBox(height: 12),
                        TextField(
                          key: const Key('activation_code'),
                          controller: widget.activationCodeController,
                          textCapitalization: TextCapitalization.characters,
                          textInputAction: TextInputAction.next,
                          decoration: const InputDecoration(
                            labelText: 'One-time activation code',
                            prefixIcon: Icon(Icons.vpn_key_outlined),
                          ),
                        ),
                      ],
                      const SizedBox(height: 12),
                      TextField(
                        key: const Key('password'),
                        controller: widget.passwordController,
                        obscureText: !_passwordVisible,
                        enableSuggestions: false,
                        autocorrect: false,
                        textInputAction: _activating
                            ? TextInputAction.next
                            : TextInputAction.done,
                        decoration: InputDecoration(
                          labelText: _activating
                              ? 'Create password'
                              : 'Password',
                          prefixIcon: const Icon(Icons.lock_outline),
                          suffixIcon: IconButton(
                            tooltip: _passwordVisible
                                ? 'Hide password'
                                : 'Show password',
                            onPressed: () => setState(
                              () => _passwordVisible = !_passwordVisible,
                            ),
                            icon: Icon(
                              _passwordVisible
                                  ? Icons.visibility_off_outlined
                                  : Icons.visibility_outlined,
                            ),
                          ),
                        ),
                      ),
                      if (_activating) ...[
                        const SizedBox(height: 12),
                        TextField(
                          key: const Key('confirm_password'),
                          controller: widget.confirmationController,
                          obscureText: !_passwordVisible,
                          enableSuggestions: false,
                          autocorrect: false,
                          textInputAction: TextInputAction.done,
                          decoration: const InputDecoration(
                            labelText: 'Confirm password',
                            prefixIcon: Icon(Icons.lock_reset),
                          ),
                        ),
                      ],
                      const SizedBox(height: 10),
                      ExpansionTile(
                        key: const Key('connection_settings'),
                        initiallyExpanded: widget.endpointController.text
                            .trim()
                            .isEmpty,
                        tilePadding: EdgeInsets.zero,
                        childrenPadding: const EdgeInsets.only(bottom: 8),
                        leading: const Icon(Icons.dns_outlined, size: 21),
                        title: const Text(
                          'Connection settings',
                          style: TextStyle(fontWeight: FontWeight.w700),
                        ),
                        subtitle: Text(
                          widget.endpointController.text.trim().isEmpty
                              ? 'Required once during setup'
                              : 'Private server configured',
                        ),
                        children: [
                          TextField(
                            key: const Key('server_address'),
                            controller: widget.endpointController,
                            keyboardType: TextInputType.url,
                            textInputAction: TextInputAction.done,
                            decoration: const InputDecoration(
                              labelText: 'Server address',
                              hintText: 'https://your-private-server',
                              prefixIcon: Icon(Icons.link),
                            ),
                          ),
                        ],
                      ),
                      if (widget.message.isNotEmpty) ...[
                        const SizedBox(height: 12),
                        MessageBanner(
                          key: const Key('auth_message'),
                          message: widget.message,
                          error: true,
                        ),
                      ],
                      const SizedBox(height: 18),
                      FilledButton.icon(
                        key: Key(_activating ? 'activate_account' : 'sign_in'),
                        onPressed: widget.busy
                            ? null
                            : (_activating
                                  ? widget.onActivate
                                  : widget.onLogin),
                        icon: Icon(
                          _activating
                              ? Icons.verified_user_outlined
                              : Icons.login,
                        ),
                        label: Text(
                          widget.busy
                              ? 'PLEASE WAIT…'
                              : (_activating ? 'ACTIVATE ACCOUNT' : 'SIGN IN'),
                        ),
                      ),
                      const SizedBox(height: 12),
                      const Text(
                        'Your face template and offline attendance records stay encrypted on this device.',
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 12, height: 1.4),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    ),
  );
}

class _AuthModeButton extends StatelessWidget {
  const _AuthModeButton({
    super.key,
    required this.label,
    required this.selected,
    required this.onPressed,
  });

  final String label;
  final bool selected;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => Material(
    color: selected
        ? driverFleetBlue.withValues(alpha: .12)
        : Theme.of(context).colorScheme.surfaceContainerHighest,
    borderRadius: BorderRadius.circular(10),
    child: InkWell(
      onTap: onPressed,
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Text(
          label,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: selected
                ? driverFleetBlue
                : Theme.of(context).colorScheme.onSurfaceVariant,
            fontWeight: FontWeight.w800,
          ),
        ),
      ),
    ),
  );
}

class MessageBanner extends StatelessWidget {
  const MessageBanner({super.key, required this.message, this.error = false});

  final String message;
  final bool error;

  @override
  Widget build(BuildContext context) {
    final color = error ? Theme.of(context).colorScheme.error : driverFleetBlue;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: .09),
        borderRadius: BorderRadius.circular(11),
        border: Border.all(color: color.withValues(alpha: .24)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(error ? Icons.error_outline : Icons.info_outline, color: color),
          const SizedBox(width: 10),
          Expanded(child: Text(message)),
        ],
      ),
    );
  }
}

class DriverShellView extends StatelessWidget {
  const DriverShellView({
    super.key,
    required this.driver,
    required this.assignment,
    required this.registered,
    required this.pendingAttempts,
    required this.busy,
    required this.cameraReady,
    required this.message,
    required this.selectedIndex,
    required this.onDestinationSelected,
    required this.onCheckIn,
    required this.onRegister,
    required this.onSynchronize,
    required this.onRefresh,
    required this.offline,
    required this.lastSyncedAt,
    required this.debugMode,
    required this.onDebugModeChanged,
    required this.onOpenDirections,
    required this.onLogout,
  });

  final DriverIdentity driver;
  final DriverAssignment? assignment;
  final bool registered;
  final List<AttendanceAttempt> pendingAttempts;
  final bool busy;
  final bool cameraReady;
  final String message;
  final int selectedIndex;
  final ValueChanged<int> onDestinationSelected;
  final VoidCallback onCheckIn;
  final VoidCallback onRegister;
  final VoidCallback onSynchronize;
  final Future<void> Function() onRefresh;
  final bool offline;
  final DateTime? lastSyncedAt;
  final bool debugMode;
  final ValueChanged<bool> onDebugModeChanged;
  final VoidCallback onOpenDirections;
  final VoidCallback onLogout;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: IndexedStack(
      index: selectedIndex,
      children: [
        DriverHomeView(
          driver: driver,
          assignment: assignment,
          registered: registered,
          queueCount: pendingAttempts.length,
          busy: busy,
          cameraReady: cameraReady,
          message: message,
          onCheckIn: onCheckIn,
          onRegister: onRegister,
          onSynchronize: onSynchronize,
          onRefresh: onRefresh,
          offline: offline,
          lastSyncedAt: lastSyncedAt,
          onOpenDirections: onOpenDirections,
        ),
        DriverActivityView(
          attempts: pendingAttempts,
          busy: busy,
          onSynchronize: onSynchronize,
          onRefresh: onRefresh,
        ),
        DriverProfileView(
          driver: driver,
          registered: registered,
          assignmentReady: assignment?.isActive == true,
          queueCount: pendingAttempts.length,
          busy: busy,
          cameraReady: cameraReady,
          onRegister: onRegister,
          onSynchronize: onSynchronize,
          onRefresh: onRefresh,
          offline: offline,
          lastSyncedAt: lastSyncedAt,
          debugMode: debugMode,
          onDebugModeChanged: onDebugModeChanged,
          onLogout: onLogout,
        ),
      ],
    ),
    bottomNavigationBar: NavigationBar(
      selectedIndex: selectedIndex,
      onDestinationSelected: onDestinationSelected,
      destinations: const [
        NavigationDestination(
          key: Key('nav_home'),
          icon: Icon(Icons.home_outlined),
          selectedIcon: Icon(Icons.home_rounded),
          label: 'Home',
        ),
        NavigationDestination(
          key: Key('nav_activity'),
          icon: Icon(Icons.receipt_long_outlined),
          selectedIcon: Icon(Icons.receipt_long_rounded),
          label: 'Activity',
        ),
        NavigationDestination(
          key: Key('nav_profile'),
          icon: Icon(Icons.person_outline),
          selectedIcon: Icon(Icons.person),
          label: 'Profile',
        ),
      ],
    ),
  );
}

class DriverHomeView extends StatelessWidget {
  const DriverHomeView({
    super.key,
    required this.driver,
    required this.assignment,
    required this.registered,
    required this.queueCount,
    required this.busy,
    required this.cameraReady,
    required this.message,
    required this.onCheckIn,
    required this.onRegister,
    required this.onSynchronize,
    required this.onRefresh,
    required this.offline,
    required this.lastSyncedAt,
    required this.onOpenDirections,
  });

  final DriverIdentity driver;
  final DriverAssignment? assignment;
  final bool registered;
  final int queueCount;
  final bool busy;
  final bool cameraReady;
  final String message;
  final VoidCallback onCheckIn;
  final VoidCallback onRegister;
  final VoidCallback onSynchronize;
  final Future<void> Function() onRefresh;
  final bool offline;
  final DateTime? lastSyncedAt;
  final VoidCallback onOpenDirections;

  @override
  Widget build(BuildContext context) {
    final hasActiveAssignment = assignment?.isActive == true;
    return RefreshIndicator(
      onRefresh: onRefresh,
      child: CustomScrollView(
        key: const PageStorageKey('driver_home'),
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          SliverToBoxAdapter(child: DriverHeader(driver: driver)),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(18, 18, 18, 28),
            sliver: SliverList.list(
              children: [
                SectionLabel(
                  title: hasActiveAssignment
                      ? 'Current delivery'
                      : 'Latest delivery',
                  trailing: assignment == null
                      ? null
                      : StatusBadge(status: assignment!.status),
                ),
                const SizedBox(height: 10),
                AssignmentCard(
                  assignment: assignment,
                  onOpenDirections: onOpenDirections,
                ),
                const SizedBox(height: 16),
                CheckInCard(
                  enabled:
                      !busy && cameraReady && hasActiveAssignment && registered,
                  registered: registered,
                  hasAssignment: hasActiveAssignment,
                  cameraReady: cameraReady,
                  onCheckIn: onCheckIn,
                  onRegister: onRegister,
                ),
                const SizedBox(height: 22),
                const SectionLabel(title: 'Ready for work'),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: ReadinessCard(
                        icon: Icons.face_retouching_natural,
                        label: 'Face',
                        value: registered ? 'Ready' : 'Setup',
                        ready: registered,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: ReadinessCard(
                        icon: Icons.location_on_outlined,
                        label: 'Location',
                        value: hasActiveAssignment ? 'Saved' : 'Waiting',
                        ready: hasActiveAssignment,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: ReadinessCard(
                        icon: queueCount == 0
                            ? Icons.cloud_done_outlined
                            : Icons.cloud_upload_outlined,
                        label: 'Sync',
                        value: queueCount == 0
                            ? 'Current'
                            : '$queueCount pending',
                        ready: queueCount == 0,
                        warning: queueCount > 0,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                SyncCard(
                  queueCount: queueCount,
                  busy: busy,
                  offline: offline,
                  lastSyncedAt: lastSyncedAt,
                  onSynchronize: onSynchronize,
                ),
                if (message.isNotEmpty) ...[
                  const SizedBox(height: 14),
                  MessageBanner(
                    key: const Key('home_message'),
                    message: message,
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class DriverHeader extends StatelessWidget {
  const DriverHeader({super.key, required this.driver});

  final DriverIdentity driver;

  @override
  Widget build(BuildContext context) {
    final firstName = driver.fullName.trim().split(RegExp(r'\s+')).first;
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [driverFleetNavyDeep, Color(0xff243a5d)],
        ),
        borderRadius: BorderRadius.vertical(bottom: Radius.circular(26)),
      ),
      child: SafeArea(
        bottom: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const FleetBrand(showName: true),
                const Spacer(),
                DriverAvatar(name: driver.fullName),
              ],
            ),
            const SizedBox(height: 28),
            const Text(
              'DRIVER WORKSPACE',
              style: TextStyle(
                color: Color(0xff9fb3cf),
                fontSize: 11,
                fontWeight: FontWeight.w800,
                letterSpacing: 1.3,
              ),
            ),
            const SizedBox(height: 5),
            Text(
              'Good day, $firstName',
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                color: Colors.white,
                fontWeight: FontWeight.w800,
                letterSpacing: -.5,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              driver.employeeId,
              style: const TextStyle(color: Color(0xffc8d6e8)),
            ),
          ],
        ),
      ),
    );
  }
}

class DriverAvatar extends StatelessWidget {
  const DriverAvatar({super.key, required this.name});

  final String name;

  @override
  Widget build(BuildContext context) {
    final parts = name.trim().split(RegExp(r'\s+'));
    final initials = parts.take(2).map((part) => part[0]).join().toUpperCase();
    return Container(
      width: 42,
      height: 42,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: Colors.white.withValues(alpha: .14),
        border: Border.all(color: Colors.white.withValues(alpha: .24)),
      ),
      child: Text(
        initials,
        style: const TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}

class SectionLabel extends StatelessWidget {
  const SectionLabel({super.key, required this.title, this.trailing});

  final String title;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Text(
        title,
        style: Theme.of(
          context,
        ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
      ),
      const Spacer(),
      ?trailing,
    ],
  );
}

class AssignmentCard extends StatelessWidget {
  const AssignmentCard({
    super.key,
    required this.assignment,
    required this.onOpenDirections,
  });

  final DriverAssignment? assignment;
  final VoidCallback onOpenDirections;

  @override
  Widget build(BuildContext context) {
    final item = assignment;
    if (item == null) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            children: [
              IconTile(
                icon: Icons.route_outlined,
                color: Theme.of(context).colorScheme.outline,
              ),
              const SizedBox(height: 14),
              Text(
                'No active delivery',
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 5),
              const Text(
                'Your next destination will appear here when your Fleet Manager assigns it.',
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );
    }
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const IconTile(icon: Icons.local_shipping_outlined),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        item.locationName,
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w800,
                          letterSpacing: -.3,
                        ),
                      ),
                      if (item.address?.trim().isNotEmpty == true) ...[
                        const SizedBox(height: 4),
                        Text(
                          item.address!,
                          style: TextStyle(
                            color: Theme.of(
                              context,
                            ).colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filledTonal(
                  key: const Key('open_directions'),
                  tooltip: 'Open directions',
                  onPressed: onOpenDirections,
                  icon: const Icon(Icons.directions_outlined),
                ),
              ],
            ),
            const SizedBox(height: 18),
            const Divider(height: 1),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: AssignmentDetail(
                    icon: Icons.schedule_outlined,
                    label: 'Schedule',
                    value: formatSchedule(item.scheduledAt),
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: AssignmentDetail(
                    icon: Icons.radar_outlined,
                    label: 'Check-in zone',
                    value: '${item.site.radiusMeters.round()} meters',
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class AssignmentDetail extends StatelessWidget {
  const AssignmentDetail({
    super.key,
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Icon(icon, size: 18, color: driverFleetBlue),
      const SizedBox(width: 8),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                fontSize: 11,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              value,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
            ),
          ],
        ),
      ),
    ],
  );
}

class CheckInCard extends StatelessWidget {
  const CheckInCard({
    super.key,
    required this.enabled,
    required this.registered,
    required this.hasAssignment,
    required this.cameraReady,
    required this.onCheckIn,
    required this.onRegister,
  });

  final bool enabled;
  final bool registered;
  final bool hasAssignment;
  final bool cameraReady;
  final VoidCallback onCheckIn;
  final VoidCallback onRegister;

  String get helper {
    if (!cameraReady) return 'Camera verification is temporarily unavailable.';
    if (!registered) {
      return 'Set up face verification before your first check-in.';
    }
    if (!hasAssignment) return 'Waiting for an active delivery assignment.';
    return 'Face verification and GPS are checked on your phone.';
  }

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(18),
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(16),
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          driverFleetBlue,
          Color.lerp(driverFleetBlue, driverFleetNavy, .32)!,
        ],
      ),
      boxShadow: const [
        BoxShadow(
          color: Color(0x302878f0),
          blurRadius: 24,
          offset: Offset(0, 12),
        ),
      ],
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Row(
          children: [
            Icon(Icons.verified_user_outlined, color: Colors.white),
            SizedBox(width: 9),
            Text(
              'Secure attendance',
              style: TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ),
        const SizedBox(height: 7),
        Text(helper, style: const TextStyle(color: Color(0xffe7f0ff))),
        const SizedBox(height: 16),
        FilledButton.icon(
          key: const Key('check_in'),
          onPressed: enabled ? onCheckIn : null,
          style: FilledButton.styleFrom(
            backgroundColor: Colors.white,
            foregroundColor: driverFleetNavy,
            disabledBackgroundColor: Colors.white.withValues(alpha: .45),
            disabledForegroundColor: driverFleetNavy.withValues(alpha: .55),
          ),
          icon: const Icon(Icons.how_to_reg_rounded),
          label: const Text('CHECK IN'),
        ),
        if (!registered && cameraReady) ...[
          const SizedBox(height: 8),
          TextButton.icon(
            key: const Key('set_up_face'),
            onPressed: onRegister,
            style: TextButton.styleFrom(foregroundColor: Colors.white),
            icon: const Icon(Icons.face_retouching_natural),
            label: const Text('Set up face verification'),
          ),
        ],
      ],
    ),
  );
}

class ReadinessCard extends StatelessWidget {
  const ReadinessCard({
    super.key,
    required this.icon,
    required this.label,
    required this.value,
    required this.ready,
    this.warning = false,
  });

  final IconData icon;
  final String label;
  final String value;
  final bool ready;
  final bool warning;

  @override
  Widget build(BuildContext context) {
    final color = warning
        ? driverFleetWarning
        : ready
        ? driverFleetSuccess
        : Theme.of(context).colorScheme.outline;
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 13),
        child: Column(
          children: [
            Icon(icon, color: color, size: 22),
            const SizedBox(height: 7),
            Text(
              label,
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                fontSize: 11,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: color,
                fontSize: 12,
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class SyncCard extends StatelessWidget {
  const SyncCard({
    super.key,
    required this.queueCount,
    required this.busy,
    required this.onSynchronize,
    required this.offline,
    required this.lastSyncedAt,
  });

  final int queueCount;
  final bool busy;
  final VoidCallback onSynchronize;
  final bool offline;
  final DateTime? lastSyncedAt;

  @override
  Widget build(BuildContext context) => Card(
    child: ListTile(
      contentPadding: const EdgeInsets.fromLTRB(14, 7, 8, 7),
      leading: IconTile(
        icon: queueCount == 0
            ? Icons.cloud_done_outlined
            : Icons.cloud_upload_outlined,
        color: queueCount == 0 ? driverFleetSuccess : driverFleetWarning,
      ),
      title: Text(
        offline
            ? 'Offline'
            : queueCount == 0
            ? 'Attendance is up to date'
            : '$queueCount check-in${queueCount == 1 ? '' : 's'} waiting to sync',
        style: const TextStyle(fontWeight: FontWeight.w800),
      ),
      subtitle: Text(
        'Last synced: ${lastSyncedAt == null ? 'Not yet' : formatDateTime(lastSyncedAt!)}',
      ),
      trailing: IconButton(
        key: const Key('synchronize'),
        tooltip: 'Synchronize',
        onPressed: busy ? null : onSynchronize,
        icon: busy
            ? const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.sync),
      ),
    ),
  );
}

class DriverActivityView extends StatelessWidget {
  const DriverActivityView({
    super.key,
    required this.attempts,
    required this.busy,
    required this.onSynchronize,
    required this.onRefresh,
  });

  final List<AttendanceAttempt> attempts;
  final bool busy;
  final VoidCallback onSynchronize;
  final Future<void> Function() onRefresh;

  @override
  Widget build(BuildContext context) => RefreshIndicator(
    onRefresh: onRefresh,
    child: CustomScrollView(
      key: const PageStorageKey('driver_activity'),
      physics: const AlwaysScrollableScrollPhysics(),
      slivers: [
        const FleetPageHeader(
          title: 'Activity',
          subtitle: 'Offline records waiting to synchronize',
        ),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(18, 20, 18, 28),
          sliver: attempts.isEmpty
              ? SliverToBoxAdapter(
                  child: EmptyState(
                    icon: Icons.cloud_done_outlined,
                    title: 'Nothing waiting to sync',
                    message:
                        'New offline check-ins will appear here until the server confirms them.',
                    action: OutlinedButton.icon(
                      key: const Key('activity_synchronize'),
                      onPressed: busy ? null : onSynchronize,
                      icon: const Icon(Icons.sync),
                      label: const Text('Check for updates'),
                    ),
                  ),
                )
              : SliverList.separated(
                  itemCount: attempts.length + 1,
                  separatorBuilder: (_, _) => const SizedBox(height: 10),
                  itemBuilder: (context, index) {
                    if (index == 0) {
                      return Row(
                        children: [
                          Expanded(
                            child: Text(
                              '${attempts.length} pending check-in${attempts.length == 1 ? '' : 's'}',
                              style: const TextStyle(
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                          TextButton.icon(
                            onPressed: busy ? null : onSynchronize,
                            icon: const Icon(Icons.sync, size: 18),
                            label: const Text('Sync now'),
                          ),
                        ],
                      );
                    }
                    return PendingAttemptCard(attempt: attempts[index - 1]);
                  },
                ),
        ),
      ],
    ),
  );
}

class PendingAttemptCard extends StatelessWidget {
  const PendingAttemptCard({super.key, required this.attempt});

  final AttendanceAttempt attempt;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          const IconTile(
            icon: Icons.how_to_reg_outlined,
            color: driverFleetWarning,
          ),
          const SizedBox(width: 13),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Check-in saved',
                  style: TextStyle(fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 3),
                Text(
                  formatDateTime(attempt.capturedAtUtc.toLocal()),
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          ),
          const StatusBadge(status: 'pending_sync'),
        ],
      ),
    ),
  );
}

class DriverProfileView extends StatelessWidget {
  const DriverProfileView({
    super.key,
    required this.driver,
    required this.registered,
    required this.assignmentReady,
    required this.queueCount,
    required this.busy,
    required this.cameraReady,
    required this.onRegister,
    required this.onSynchronize,
    required this.onRefresh,
    required this.offline,
    required this.lastSyncedAt,
    required this.debugMode,
    required this.onDebugModeChanged,
    required this.onLogout,
  });

  final DriverIdentity driver;
  final bool registered;
  final bool assignmentReady;
  final int queueCount;
  final bool busy;
  final bool cameraReady;
  final VoidCallback onRegister;
  final VoidCallback onSynchronize;
  final Future<void> Function() onRefresh;
  final bool offline;
  final DateTime? lastSyncedAt;
  final bool debugMode;
  final ValueChanged<bool> onDebugModeChanged;
  final VoidCallback onLogout;

  @override
  Widget build(BuildContext context) => RefreshIndicator(
    onRefresh: onRefresh,
    child: CustomScrollView(
      key: const PageStorageKey('driver_profile'),
      physics: const AlwaysScrollableScrollPhysics(),
      slivers: [
        const FleetPageHeader(
          title: 'Profile',
          subtitle: 'Account and device readiness',
        ),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(18, 20, 18, 28),
          sliver: SliverList.list(
            children: [
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(18),
                  child: Row(
                    children: [
                      DriverAvatar(name: driver.fullName),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              driver.fullName,
                              style: Theme.of(context).textTheme.titleLarge
                                  ?.copyWith(fontWeight: FontWeight.w800),
                            ),
                            Text(
                              driver.employeeId,
                              style: TextStyle(
                                color: Theme.of(
                                  context,
                                ).colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const StatusBadge(status: 'active'),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 20),
              const SectionLabel(title: 'Device readiness'),
              const SizedBox(height: 10),
              Card(
                child: Column(
                  children: [
                    ProfileStatusRow(
                      icon: Icons.face_retouching_natural,
                      title: 'Face verification',
                      value: registered
                          ? 'Ready on this device'
                          : 'Setup required',
                      ready: registered,
                    ),
                    const Divider(height: 1, indent: 62),
                    ProfileStatusRow(
                      icon: Icons.location_on_outlined,
                      title: 'Delivery location',
                      value: assignmentReady
                          ? 'Saved for offline use'
                          : 'No active assignment',
                      ready: assignmentReady,
                    ),
                    const Divider(height: 1, indent: 62),
                    ProfileStatusRow(
                      icon: Icons.cloud_outlined,
                      title: 'Attendance sync',
                      value: queueCount == 0
                          ? offline
                                ? 'Offline'
                                : 'Synced${lastSyncedAt == null ? '' : ' ${formatDateTime(lastSyncedAt!)}'}'
                          : '$queueCount waiting to sync',
                      ready: queueCount == 0,
                      warning: queueCount > 0,
                    ),
                  ],
                ),
              ),
              if (!registered && cameraReady) ...[
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  key: const Key('profile_set_up_face'),
                  onPressed: busy ? null : onRegister,
                  icon: const Icon(Icons.face_retouching_natural),
                  label: const Text('Set up face verification'),
                ),
              ],
              const SizedBox(height: 20),
              const SectionLabel(title: 'Account'),
              const SizedBox(height: 10),
              Card(
                child: Column(
                  children: [
                    const ListTile(
                      leading: Icon(Icons.dns_outlined),
                      title: Text('Private server'),
                      subtitle: Text('Connection configured securely'),
                      trailing: Icon(Icons.lock_outline, size: 20),
                    ),
                    const Divider(height: 1, indent: 56),
                    ListTile(
                      key: const Key('profile_synchronize'),
                      onTap: busy ? null : onSynchronize,
                      leading: const Icon(Icons.sync),
                      title: const Text('Synchronize now'),
                      subtitle: const Text('Refresh assignment and attendance'),
                      trailing: const Icon(Icons.chevron_right),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              const SectionLabel(title: 'Settings'),
              const SizedBox(height: 10),
              Card(
                child: SwitchListTile(
                  key: const Key('debug_mode'),
                  value: debugMode,
                  onChanged: busy ? null : onDebugModeChanged,
                  secondary: const Icon(Icons.bug_report_outlined),
                  title: const Text('Debug Mode'),
                  subtitle: const Text(
                    'Show technical camera details for troubleshooting',
                  ),
                ),
              ),
              const SizedBox(height: 16),
              OutlinedButton.icon(
                key: const Key('logout'),
                onPressed: busy ? null : onLogout,
                style: OutlinedButton.styleFrom(
                  foregroundColor: Theme.of(context).colorScheme.error,
                  side: BorderSide(color: Theme.of(context).colorScheme.error),
                  minimumSize: const Size(0, 50),
                ),
                icon: const Icon(Icons.logout),
                label: const Text('SIGN OUT'),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

class ProfileStatusRow extends StatelessWidget {
  const ProfileStatusRow({
    super.key,
    required this.icon,
    required this.title,
    required this.value,
    required this.ready,
    this.warning = false,
  });

  final IconData icon;
  final String title;
  final String value;
  final bool ready;
  final bool warning;

  @override
  Widget build(BuildContext context) {
    final color = warning
        ? driverFleetWarning
        : ready
        ? driverFleetSuccess
        : Theme.of(context).colorScheme.outline;
    return ListTile(
      leading: Icon(icon, color: color),
      title: Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
      subtitle: Text(value),
      trailing: Icon(
        ready ? Icons.check_circle : Icons.info_outline,
        color: color,
        size: 21,
      ),
    );
  }
}

class FleetPageHeader extends StatelessWidget {
  const FleetPageHeader({
    super.key,
    required this.title,
    required this.subtitle,
  });

  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) => SliverToBoxAdapter(
    child: Container(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 24),
      decoration: const BoxDecoration(
        color: driverFleetNavy,
        borderRadius: BorderRadius.vertical(bottom: Radius.circular(24)),
      ),
      child: SafeArea(
        bottom: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const FleetBrand(showName: true),
            const SizedBox(height: 26),
            Text(
              title,
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                color: Colors.white,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 3),
            Text(subtitle, style: const TextStyle(color: Color(0xffc8d6e8))),
          ],
        ),
      ),
    ),
  );
}

class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    required this.message,
    this.action,
  });

  final IconData icon;
  final String title;
  final String message;
  final Widget? action;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.fromLTRB(24, 32, 24, 28),
      child: Column(
        children: [
          IconTile(icon: icon, color: driverFleetSuccess, size: 50),
          const SizedBox(height: 16),
          Text(
            title,
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 6),
          Text(message, textAlign: TextAlign.center),
          if (action != null) ...[const SizedBox(height: 18), action!],
        ],
      ),
    ),
  );
}

class IconTile extends StatelessWidget {
  const IconTile({
    super.key,
    required this.icon,
    this.color = driverFleetBlue,
    this.size = 42,
  });

  final IconData icon;
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    alignment: Alignment.center,
    decoration: BoxDecoration(
      color: color.withValues(alpha: .12),
      borderRadius: BorderRadius.circular(size * .29),
    ),
    child: Icon(icon, color: color, size: size * .5),
  );
}

class StatusBadge extends StatelessWidget {
  const StatusBadge({super.key, required this.status});

  final String status;

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (status) {
      'assigned' => ('Assigned', driverFleetWarning),
      'in_progress' => ('In progress', const Color(0xff8b61e8)),
      'completed' => ('Delivered', driverFleetSuccess),
      'pending_sync' => ('Pending', driverFleetWarning),
      'active' => ('Active', driverFleetSuccess),
      _ => (status.replaceAll('_', ' '), Theme.of(context).colorScheme.outline),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: .12),
        borderRadius: BorderRadius.circular(99),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              color: color,
              fontSize: 11,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }
}

String formatSchedule(DateTime? value) {
  if (value == null) return 'Not scheduled';
  return formatDateTime(value);
}

String formatDateTime(DateTime value) {
  const months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  final hour = value.hour == 0
      ? 12
      : value.hour > 12
      ? value.hour - 12
      : value.hour;
  final minute = value.minute.toString().padLeft(2, '0');
  final period = value.hour >= 12 ? 'PM' : 'AM';
  return '${months[value.month - 1]} ${value.day}, $hour:$minute $period';
}
