/// Scheduling runs exclusively on the backend; this adapter syncs UI changes.
class ProactiveMessageScheduler {
  static final instance = ProactiveMessageScheduler();
  void Function(String chatId)? onMessageSent;
  Future<void> init() async {}
  void scheduleForRole(String roleId) => onRoleConfigChanged(roleId);
  void cancelForRole(String roleId) {}
  void cancelAll() {}
  // RoleService.updateRole already synchronizes this configuration once.
  void onRoleConfigChanged(String roleId) {}
}
