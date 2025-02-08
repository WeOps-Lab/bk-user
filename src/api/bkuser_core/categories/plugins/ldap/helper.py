# -*- coding: utf-8 -*-
"""
TencentBlueKing is pleased to support the open source community by making 蓝鲸智云-用户管理(Bk-User) available.
Copyright (C) 2017-2021 THL A29 Limited, a Tencent company. All rights reserved.
Licensed under the MIT License (the "License"); you may not use this file except in compliance with the License.
You may obtain a copy of the License at http://opensource.org/licenses/MIT
Unless required by applicable law or agreed to in writing, software distributed under the License is distributed on
an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the License for the
specific language governing permissions and limitations under the License.
"""
import logging
from dataclasses import dataclass
from typing import Dict, List, Optional, Type

from django.db.models import Model
from django.utils.functional import cached_property
from django.utils.translation import gettext_lazy as _
from rest_framework.exceptions import ValidationError

from bkuser_core.categories.models import ProfileCategory
from bkuser_core.categories.plugins.base import DBSyncManager, SyncContext, SyncStep, TypeList
from bkuser_core.categories.plugins.ldap.metas import LdapDepartmentMeta, LdapProfileMeta
from bkuser_core.categories.plugins.ldap.models import LdapDepartment, LdapUserProfile
from bkuser_core.categories.plugins.utils import handle_with_progress_info
from bkuser_core.common.db_sync import SyncOperation
from bkuser_core.departments.models import Department, DepartmentThroughModel
from bkuser_core.profiles.constants import ProfileStatus
from bkuser_core.profiles.models import Profile, LeaderThroughModel
from bkuser_core.profiles.validators import validate_username
from bkuser_core.user_settings.loader import ConfigProvider

logger = logging.getLogger(__name__)


@dataclass
class DepartmentSyncHelper:
    category: ProfileCategory
    db_sync_manager: DBSyncManager
    target_obj_list: TypeList[LdapDepartment]
    context: SyncContext
    config_loader: ConfigProvider

    _MPTT_INIT_PARAMS = {
        "tree_id": 0,
        "lft": 0,
        "rght": 0,
        "level": 0,
    }

    @cached_property
    def db_departments(self) -> Dict[str, Department]:
        # 由于 bulk_update 需要从数据库查询完整的 Department 信息, 为提高查询效率, 统一执行查询操作, 减轻数据库负担
        all_departments: List[Department] = list(Department.objects.filter(category_id=self.category.pk))

        def make_key(dept: Department):
            names = []
            while dept:
                names.append(dept.name)
                dept = dept.parent
            return "/".join(reversed(names))

        return {make_key(dept): dept for dept in all_departments}

    def load_to_memory(self):
        for dept in handle_with_progress_info(
                self.target_obj_list, progress_title="handle department"
        ):  # type: LdapDepartment
            self._handle_department(dept)

    def _handle_department(self, dept_info: LdapDepartment) -> Optional[Department]:
        """将 DepartmentProfile 转换成 Department, 并递归处理其父节点

        如果父节点存在, 则递归处理父节点, 并绑定部门上下级关系, 再将部门对象(Department)插入缓存层
        如果父节点不存在, 则直接将部门对象(Department)插入缓存层
        """
        # NOTE: 注意, dept_info.parent 不带code字段, syncer->adaptor拼接的时候没放(除非能拿到每个节点的dn)
        if dept_info.parent:
            parent_dept = self._handle_department(dept_info.parent)
        else:
            parent_dept = None

        # FIXME: https://github.com/TencentBlueKing/bk-user/issues/714
        # BUG: here, the code is full_name, not the real code
        defaults = {
            # 当 self._handle_department(dept_info.parent) 逻辑执行到这里的时候, 没有code, 所以用的full_name
            "code": dept_info.key_field,
            "category_id": self.category.pk,
            "name": dept_info.name,
            "enabled": True,
            "parent_id": getattr(parent_dept, "pk", None),
            "extras": {
                "type": self.config_loader["user_group_class"]
                if dept_info.is_group
                else self.config_loader["organization_class"],
            },
            **self._MPTT_INIT_PARAMS,
        }
        dept = self._insert_dept(dept_info=dept_info, defaults=defaults)
        return dept

    def _insert_dept(self, dept_info: LdapDepartment, defaults: Dict) -> Department:
        # BUG: here, use dept_info.key_field to get dept -> it's full_name, not the code
        # the defaults["code"] is the not the `code`, it's the full_name
        dept: Department = self.db_sync_manager.magic_get(dept_info.key_field, LdapDepartmentMeta)
        if dept:
            # Question: here update the code to real code, without magic_add, will not saved into db?
            if dept_info.code and dept.code != dept_info.code:
                dept.code = dept_info.code
            return dept

        # NOTE: 如果full_name在 db 里面已经有了, 这里是判断不出来的, 因为self.db_departments是当前category的集合, 不是全局的
        # 但是code字段是 db unique字段
        if dept_info.key_field in self.db_departments:
            dept = self.db_departments[dept_info.key_field]
            for key, value in defaults.items():
                setattr(dept, key, value)
            self.db_sync_manager.magic_add(dept, SyncOperation.UPDATE.value)
        else:
            defaults["pk"] = self.db_sync_manager.register_id(LdapDepartmentMeta)
            # BUG: here, defaults["code"] is the full_name, not the code, saved into db
            # Question: key_field能否加上 category_id, 保证唯一性?
            # Question: 如何鉴权存量数据?
            dept = Department(**defaults)
            self.db_sync_manager.magic_add(dept, SyncOperation.ADD.value)

        self.context.add_record(step=SyncStep.DEPARTMENTS, success=True, department=dept_info.key_field)
        return dept


@dataclass
class ProfileSyncHelper:
    category: ProfileCategory
    db_sync_manager: DBSyncManager
    target_obj_list: TypeList[LdapUserProfile]
    context: SyncContext

    @cached_property
    def db_profiles(self) -> Dict[str, Profile]:
        # 由于 bulk_update 需要从数据库查询完整的 Profile 信息, 为提高查询效率, 统一执行查询操作, 减轻数据库负担
        return {profile.username: profile for profile in Profile.objects.filter(category_id=self.category.pk).all()}

    @cached_property
    def db_departments(self) -> Dict[str, Department]:
        # 由于 bulk_update 需要从数据库查询完整的 Department 信息, 为提高查询效率, 统一执行查询操作, 减轻数据库负担
        all_departments: List[Department] = list(Department.objects.filter(category_id=self.category.pk, enabled=True))

        def make_key(dept: Department):
            names = []
            while dept:
                names.append(dept.name)
                dept = dept.parent
            return "/".join(reversed(names))

        return {make_key(dept): dept for dept in all_departments}

    def _load_base_info(self):
        profile_ids = set()
        for info in handle_with_progress_info(self.target_obj_list, progress_title="handle profile"):
            try:
                validate_username(value=info.username)
            except ValidationError as e:
                self.context.add_record(
                    step=SyncStep.USERS,
                    success=False,
                    username=info.username,
                    error=str(e),
                )
                logger.warning("username<%s> does not meet format, will skip", info.username)
                continue

            # 1. 先更新 profile 本身
            profile_params = {
                "category_id": self.category.pk,
                "domain": self.category.domain,
                "enabled": True,
                "username": info.username,
                "display_name": info.display_name,
                "email": info.email,
                "code": info.code,
                "telephone": info.telephone,
                "status": ProfileStatus.NORMAL.value,
                "extras": info.extras,
            }

            # 2. 更新或创建 Profile 对象
            if info.username in self.db_profiles:
                profile = self.db_profiles[info.username]
                for key, value in profile_params.items():
                    setattr(profile, key, value)
                self.db_sync_manager.magic_add(profile, SyncOperation.UPDATE.value)
                profile_ids.add(profile.id)
            else:
                profile = Profile(**profile_params)
                if self.db_sync_manager.magic_exists(profile):
                    # 如果增加用户的行为已经添加过了, 则使用内存中的 Profile
                    logger.debug(
                        "profile<%s> already add into db sync manager, only get",
                        profile,
                    )
                    profile = self.db_sync_manager.magic_get(info.code, LdapProfileMeta)
                else:
                    profile.id = self.db_sync_manager.register_id(LdapProfileMeta)
                    self.db_sync_manager.magic_add(profile, SyncOperation.ADD.value)
                    profile_ids.add(profile.id)

            # 3. 维护关联关系
            for full_department_name_list in info.departments:
                department_key = "/".join(full_department_name_list)
                department = self.db_departments.get(department_key, None)
                if not department:
                    self.context.add_record(
                        step=SyncStep.DEPT_USER_RELATIONSHIP,
                        success=False,
                        username=info.username,
                        department=department_key,
                        error=_("部门不存在"),
                    )
                    logger.warning(
                        "the department<%s> of profile<%s> is missing, will skip",
                        department_key,
                        info.username,
                    )
                    continue

                self.try_add_relation(
                    params={"profile_id": profile.pk, "department_id": department.pk},
                    target_model=DepartmentThroughModel,
                )
                self.context.add_record(
                    step=SyncStep.DEPT_USER_RELATIONSHIP,
                    success=True,
                    username=info.username,
                    department=department.name,
                )
            self.context.add_record(step=SyncStep.USERS, success=True, username=info.username)
        self.profile_ids = profile_ids

    def _load_leader_info(self):
        # 加载上下级关系
        # WeOps改造,记录原有的上级关系
        raw_leader_map = tuple(
            LeaderThroughModel.objects.filter(
                from_profile_id__in=[profile.id for profile in self.db_profiles.values()]).values_list(
                "from_profile_id",
                "to_profile_id"))
        logger.info(f"load leader info start, raw_leader_map: {raw_leader_map}")
        add_leader_map = list()
        for from_profile_id, to_profile_id in raw_leader_map:
            if from_profile_id not in self.profile_ids or to_profile_id not in self.profile_ids:
                continue
            self.try_add_relation(
                params={"from_profile_id": from_profile_id, "to_profile_id": to_profile_id},
                target_model=LeaderThroughModel,
            )
            add_leader_map.append((from_profile_id, to_profile_id))
        logger.info(f"load leader info done, add_leader_map: {add_leader_map}")
        # TODO record记录

    def load_to_memory(self):
        self._load_base_info()
        # TODO: 支持处理上下级关系
        # WeOps:支持从原上下级关系中获取上下级关系
        self._load_leader_info()

    def try_add_relation(self, params: dict, target_model: Type[Model]):
        """增加关联关系"""
        logger.debug("trying to add relation: %s", params)
        relation = target_model(**params)
        self.db_sync_manager.magic_add(relation)
