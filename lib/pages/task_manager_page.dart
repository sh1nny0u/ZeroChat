import 'package:flutter/material.dart';
import '../services/task_service.dart';

/// 任务管理页面（单角色）
class TaskManagerPage extends StatefulWidget {
  final String roleId;
  final String roleName;

  const TaskManagerPage({
    super.key,
    required this.roleId,
    required this.roleName,
  });

  @override
  State<TaskManagerPage> createState() => _TaskManagerPageState();
}

class _TaskManagerPageState extends State<TaskManagerPage> {
  List<ScheduledTask> _tasks = [];

  @override
  void initState() {
    super.initState();
    _loadTasks();
    TaskService.changes.addListener(_loadTasks);
  }

  @override
  void dispose() { TaskService.changes.removeListener(_loadTasks); super.dispose(); }

  void _loadTasks() {
    setState(() {
      _tasks = TaskService.getTasksForChat(
        widget.roleId,
      ).toList();
      _tasks.sort((a, b) => a.triggerTime.compareTo(b.triggerTime));
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xFFEDEDED),
        foregroundColor: const Color(0xFF000000),
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: true,
        title: Text(
          '${widget.roleName} 的定时任务',
          style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w500),
        ),
        leading: IconButton(
          onPressed: () => Navigator.pop(context),
          icon: const Icon(Icons.arrow_back_ios, size: 20),
        ),
      ),
      body: Container(
        color: const Color(0xFFEDEDED),
        child: _tasks.isEmpty ? _buildEmptyState() : _buildTaskList(),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _showAddTaskDialog,
        backgroundColor: const Color(0xFF07C160),
        child: const Icon(Icons.add, color: Colors.white),
      ),
    );
  }

  Widget _buildEmptyState() {
    return const Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.alarm_off, size: 64, color: Color(0xFFCCCCCC)),
          SizedBox(height: 16),
          Text(
            '暂无定时任务',
            style: TextStyle(color: Color(0xFF888888), fontSize: 16),
          ),
          SizedBox(height: 8),
          Text(
            '点击右下角添加',
            style: TextStyle(color: Color(0xFFBBBBBB), fontSize: 14),
          ),
        ],
      ),
    );
  }

  Widget _buildTaskList() {
    return ListView.builder(
      padding: const EdgeInsets.all(12),
      itemCount: _tasks.length,
      itemBuilder: (context, index) {
        final task = _tasks[index];
        return _buildTaskItem(task);
      },
    );
  }

  Widget _buildTaskItem(ScheduledTask task) {
    final isPast = task.triggerTime.isBefore(DateTime.now());

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 4,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: ListTile(
        leading: Icon(
          Icons.alarm,
          color: isPast ? const Color(0xFFCCCCCC) : const Color(0xFF07C160),
        ),
        title: Text(task.message, style: const TextStyle(fontSize: 15)),
        subtitle: Text(
          '${_formatTime(task.triggerTime)}${task.lastStatus == 'failed' ? '\n供应商处理失败，可手动重试' : task.lastStatus == 'uncertain' ? '\n结果未确认，请先检查聊天记录，未重复调用' : ''}',
          style: TextStyle(
            fontSize: 13,
            color: isPast ? Colors.red : const Color(0xFF888888),
          ),
        ),
        trailing: task.lastStatus == 'failed' && task.isCompleted ? TextButton(
          onPressed: () async {
            try { await TaskService.retryTask(task.id); if (mounted) _loadTasks(); }
            catch (error) { if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$error'))); }
          }, child: const Text('重试')) : IconButton(
          onPressed: () => _deleteTask(task),
          icon: const Icon(Icons.delete_outline, color: Color(0xFFCCCCCC)),
        ),
      ),
    );
  }

  void _showAddTaskDialog() {
    final messageController = TextEditingController();
    DateTime selectedTime = DateTime.now().add(const Duration(hours: 1));

    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('添加定时任务'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: messageController,
                  decoration: const InputDecoration(
                    labelText: '提醒内容',
                    hintText: '例如：该喝水了',
                    border: OutlineInputBorder(),
                  ),
                  maxLines: 2,
                ),
                const SizedBox(height: 16),
                Text(
                  '触发时间：${_formatTime(selectedTime)}',
                  style: const TextStyle(fontSize: 14),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    ElevatedButton(
                      onPressed: () async {
                        final date = await showDatePicker(
                          context: context,
                          initialDate: selectedTime,
                          firstDate: DateTime.now(),
                          lastDate: DateTime.now().add(
                            const Duration(days: 365),
                          ),
                        );
                        if (date != null && context.mounted) {
                          final time = await showTimePicker(
                            context: context,
                            initialTime: TimeOfDay.fromDateTime(selectedTime),
                          );
                          if (time != null) {
                            setDialogState(() {
                              selectedTime = DateTime(
                                date.year,
                                date.month,
                                date.day,
                                time.hour,
                                time.minute,
                              );
                            });
                          }
                        }
                      },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFFF5F5F5),
                        foregroundColor: const Color(0xFF333333),
                      ),
                      child: const Text('选择时间'),
                    ),
                    const SizedBox(width: 8),
                    // 快捷时间
                    TextButton(
                      onPressed: () {
                        setDialogState(() {
                          selectedTime = DateTime.now().add(
                            const Duration(minutes: 30),
                          );
                        });
                      },
                      child: const Text('30分钟'),
                    ),
                    TextButton(
                      onPressed: () {
                        setDialogState(() {
                          selectedTime = DateTime.now().add(
                            const Duration(hours: 1),
                          );
                        });
                      },
                      child: const Text('1小时'),
                    ),
                  ],
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            ElevatedButton(
              onPressed: () async {
                final message = messageController.text.trim();
                if (message.isEmpty) return;

                try { await TaskService.addReminder(
                  chatId: widget.roleId,
                  roleId: widget.roleId,
                  message: message,
                  triggerTime: selectedTime,
                ); } catch (error) {
                  if (mounted) ScaffoldMessenger.of(this.context).showSnackBar(SnackBar(content: Text('$error')));
                  return;
                }

                if (context.mounted) {
                  Navigator.pop(context);
                  _loadTasks();
                }
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF07C160),
                foregroundColor: Colors.white,
              ),
              child: const Text('添加'),
            ),
          ],
        ),
      ),
    );
  }

  void _deleteTask(ScheduledTask task) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除任务'),
        content: const Text('确定要删除这个定时任务吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () async {
              try { await TaskService.cancelTask(task.id); if (context.mounted) Navigator.pop(context); if (mounted) _loadTasks(); }
              catch (error) { if (mounted) ScaffoldMessenger.of(this.context).showSnackBar(SnackBar(content: Text('$error'))); }
            },
            child: const Text('删除', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }

  String _formatTime(DateTime time) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final targetDay = DateTime(time.year, time.month, time.day);
    final timeStr =
        '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';

    if (targetDay == today) {
      return '今天 $timeStr';
    } else if (targetDay == today.add(const Duration(days: 1))) {
      return '明天 $timeStr';
    } else {
      return '${time.month}/${time.day} $timeStr';
    }
  }
}
