# -*- coding: utf-8 -*-
"""
This file contains the Qudi task runner module.

Qudi is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

Qudi is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with Qudi. If not, see <http://www.gnu.org/licenses/>.

Copyright (c) the Qudi Developers. See the COPYRIGHT.txt file at the
top-level directory of this distribution and at <https://github.com/Ulm-IQO/qudi/>
"""

import importlib
from uuid import uuid4
from functools import partial
from PySide2 import QtCore, QtWidgets
from typing import Any, Optional, Type, Iterable, Mapping, Tuple, Union, List, Dict

from qudi.util.mutex import Mutex
from qudi.core.module import LogicBase
from qudi.core.scripting.moduletask import ModuleTask
from qudi.core.scripting.modulescript import import_module_script
from qudi.core.configoption import ConfigOption


class ModuleTasksTableModel(QtCore.QAbstractTableModel):
    """ An extension of the ListTableModel for keeping ModuleTask instances """
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self._headers = ('Task Name', 'Current State', 'Result', 'Involved Modules')
        self._names = list()
        self._tasks = list()

    def rowCount(self, parent: Optional[QtCore.QModelIndex] = None) -> int:
        """ Gives the number of stored items (rows) """
        return len(self._names)

    def columnCount(self, parent: Optional[QtCore.QModelIndex] = None) -> int:
        """ Gives the number of data fields (columns) """
        return 4

    def flags(self, index: QtCore.QModelIndex) -> QtCore.Qt.ItemFlags:
        """ Determines what can be done with entry cells in the table view """
        return QtCore.Qt.ItemIsEnabled | QtCore.Qt.ItemIsSelectable

    def data(self, index: QtCore.QModelIndex,
             role: QtCore.Qt.ItemDataRole) -> Union[str, None]:
        """ Get data from model for a given cell. Data can have a role that affects display. """
        if index.isValid() and role == QtCore.Qt.DisplayRole:
            name, task = self._task_from_index(index.row())
            if index.column() == 0:
                return name
            elif index.column() == 1:
                return task.state
            elif index.column() == 2:
                return str(task.result)
            elif index.column() == 3:
                return '\n'.join(task.connected_modules.values())
        return None

    def headerData(self, section: int, orientation: QtCore.Qt.Orientation,
                   role: Optional[QtCore.Qt.ItemDataRole] = QtCore.Qt.DisplayRole) -> Union[str, None]:
        """ Data for the table view headers """
        if role == QtCore.Qt.DisplayRole:
            if orientation == QtCore.Qt.Horizontal:
                return self._headers[section]
        return None

    def add_task(self, name: str, task: ModuleTask) -> None:
        if name in self._names:
            raise KeyError(f'ModuleTask with name "{name}" already added.')
        row = self.rowCount()
        self.beginInsertRows(QtCore.QModelIndex(), row, row)
        self._names.append(name)
        self._tasks.append(task)
        task.sigStateChanged.connect(self._state_changed_callback)
        task.sigFinished.connect(self._finished_callback)
        self.endInsertRows()

    def remove_task(self, name: str) -> None:
        row = self._names.index(name)
        self.beginRemoveRows(QtCore.QModelIndex(), row, row)
        del self._names[row]
        task = self._tasks.pop(row)
        task.sigStateChanged.disconnect()
        task.sigFinished.disconnect()
        self.endRemoveRows()

    def clear_tasks(self) -> None:
        self.beginResetModel()
        for task in self._tasks:
            task.sigStateChanged.disconnect()
            task.sigFinished.disconnect()
        self._names = list()
        self._tasks = list()
        self.endResetModel()

    def task_from_index(self, index: int) -> Tuple[str, ModuleTask]:
        """ """
        return self._names[index], self._tasks[index]

    def index_from_name(self, name: str) -> int:
        """ """
        return self._names.index(name)

    @QtCore.Slot()
    def _state_changed_callback(self) -> None:
        """ Is called upon sigStateChanged signal emit of any ModuleTask instance.
        """
        task = self.sender()
        row = self._tasks.index(task)
        index = self.index(row, 1)
        self.dataChanged.emit(index, index)

    @QtCore.Slot()
    def _finished_callback(self) -> None:
        """ Is called upon sigFinished signal emit of any ModuleTask instance.
        """
        task = self.sender()
        row = self._tasks.index(task)
        index = self.index(row, 2)
        self.dataChanged.emit(index, index)


class TaskRunner(LogicBase):
    """ This module keeps a collection of available ModuleTask subclasses (defined by config) and
    respective initialized instances that can be run.
    Handles module connections to tasks and allows monitoring of task states and results.
    """

    _module_task_configs = ConfigOption(name='module_tasks', default=dict(), missing='warn')

    sigTaskStarted = QtCore.Signal(str)  # task name
    sigTaskStateChanged = QtCore.Signal(str, str)  # task name, task state
    sigTaskFinished = QtCore.Signal(str, object, bool)  # task name, result, success flag
    _sigStartTask = QtCore.Signal(str, tuple, dict)  # task name, args, kwargs

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self._thread_lock = Mutex()
        self._running_tasks = dict()
        self._configured_task_types = dict()

    def on_activate(self) -> None:
        """ Initialise task runner """
        self._running_tasks = dict()
        self._configured_task_types = dict()
        for name, task_cfg in self._module_task_configs.items():
            if name in self._configured_task_types:
                raise KeyError(f'Duplicate task name "{name}" encountered in config')
            module, cls = task_cfg['module.Class'].rsplit('.', 1)
            task = import_module_script(module, cls, reload=False)
            if not issubclass(task, ModuleTask):
                raise TypeError('Configured task is not a ModuleTask (sub)class')
            self._configured_task_types[name] = task
        self._sigStartTask.connect(self._run_task, QtCore.Qt.QueuedConnection)

    def on_deactivate(self) -> None:
        """ Shut down task runner """
        self._sigStartTask.disconnect()
        for task in self._running_tasks.values():
            task.interrupt
        self._configured_task_types = dict()

    @property
    def running_tasks(self) -> List[str]:
        with self._thread_lock:
            return list(self._running_tasks)

    @property
    def configured_task_types(self) -> Dict[str, Type[ModuleTask]]:
        return self._configured_task_types.copy()

    def run_task(self, name: str, args: Iterable[Any], kwargs: Mapping[str, Any]):
        with self._thread_lock:
            self._sigStartTask.emit(name, tuple(args), dict(kwargs))

    def interrupt_task(self, name: str) -> None:
        with self._thread_lock:
            task = self._running_tasks.get(name, None)
            if task is None:
                raise RuntimeError(f'No ModuleTask with name "{name}" running')
            task.interrupt()

    @QtCore.Slot(str, tuple, dict)
    def _run_task(self, name: str, args: Iterable, kwargs: Mapping[str, Any]) -> None:
        with self._thread_lock:
            task = self.__init_task(name)
            self.__set_task_arguments(task, args, kwargs)
            self.__activate_connect_task_modules(name, task)
            self.__move_task_into_thread(name, task)
            self.__connect_task_signals(name, task)
            self.__start_task(name, task)
            self.sigTaskStarted.emit(name)

    def _task_finished_callback(self, name: str) -> None:
        """ Called every time a task finishes """
        with self._thread_lock:
            task = self._running_tasks.get(name, None)
            if task is not None:
                task.sigFinished.disconnect()
                task.sigStateChanged.disconnect()
                task.disconnect_modules()
                thread_manager = self._qudi_main.thread_manager
                thread_manager.quit_thread(task.thread())
                thread_manager.join_thread(task.thread())

    def _thread_finished_callback(self, name: str) -> None:
        with self._thread_lock:
            task = self._running_tasks.pop(name, None)
            if task is not None:
                self.sigTaskFinished.emit(name, task.result, task.success)

    def _task_state_changed_callback(self, state: str, name: str) -> None:
        self.sigTaskStateChanged.emit(name, state)

    def __init_task(self, name: str) -> ModuleTask:
        """ Create a ModuleTask instance """
        try:
            if name in self._running_tasks:
                raise RuntimeError(f'ModuleTask "{name}" is already initialized')
            return self._configured_task_types[name]()
        except:
            self.log.exception(f'Exception during initialization of ModuleTask "{name}":')
            raise

    def __set_task_arguments(self, task: ModuleTask, args: Iterable, kwargs: Mapping[str, Any]) -> None:
        """ Set arguments for ModuleTask instance """
        try:
            if not isinstance(args, Iterable):
                raise TypeError('ModuleTask args must be iterable')
            if not isinstance(kwargs, Mapping) or not all(isinstance(kw, str) for kw in kwargs):
                raise TypeError('ModuleTask kwargs must be mapping with str type keys')
            task.args = args
            task.kwargs = kwargs
        except:
            self.log.exception(f'Exception during setting of arguments for ModuleTask:')
            raise

    def __activate_connect_task_modules(self, name: str, task: ModuleTask) -> None:
        """ Activate and connect all configured module connectors for ModuleTask """
        try:
            module_manager = self._qudi_main.module_manager
            connect_targets = dict()
            for conn_name, module_name in self._module_task_configs[name]['connect'].items():
                module = module_manager[module_name]
                module.activate()
                connect_targets[conn_name] = module.instance
            task.connect_modules(connect_targets)
        except:
            self.log.exception(f'Exception during modules connection for ModuleTask "{name}":')
            task.disconnect_modules()
            raise

    def __move_task_into_thread(self, name: str, task: ModuleTask) -> None:
        """ Create a new QThread via qudi thread manager and move ModuleTask instance into it """
        try:
            thread = self._qudi_main.thread_manager.get_new_thread(name=f'ModuleTask-{name}')
            if thread is None:
                raise RuntimeError(f'Unable to create QThread with name "ModuleTask-{name}"')
        except RuntimeError:
            self.log.exception('Exception during thread creation:')
            raise
        task.moveToThread(thread)
        thread.started.connect(task.run, QtCore.Qt.QueuedConnection)
        thread.finished.connect(partial(self._thread_finished_callback, name=name))

    def __connect_task_signals(self, name: str, task: ModuleTask) -> None:
        task.sigFinished.connect(partial(self._task_finished_callback, name=name),
                                 QtCore.Qt.QueuedConnection)
        task.sigStateChanged.connect(partial(self._task_state_changed_callback, name=name),
                                     QtCore.Qt.QueuedConnection)

    def __start_task(self, name: str, task: ModuleTask) -> None:
        self._running_tasks[name] = task
        task.thread().start()
