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
from django.utils.module_loading import import_string
from django.utils.deprecation import MiddlewareMixin
from bkuser_shell.account.conf import ConfFixture


class CrossCSRF4WEOPS(MiddlewareMixin):
    def process_request(self, request):
        # weops微前端定义得参数为AUTH-APP
        auth_app = request.META.get("HTTP_AUTH_APP")
        # 当自定义参数为"WEOPS"时，豁免csrf验证
        if auth_app and auth_app == "WEOPS":
            setattr(request, "_dont_enforce_csrf_checks", True)
            

def load_middleware(middleware):
    path = "bkuser_shell.account.components.{middleware}".format(middleware=middleware)
    return import_string(path)


if hasattr(ConfFixture, "LOGIN_REQUIRED_MIDDLEWARE"):
    LoginRequiredMiddleware = load_middleware(ConfFixture.LOGIN_REQUIRED_MIDDLEWARE)

if hasattr(ConfFixture, "BK_JWT_MIDDLEWARE"):
    BkJwtLoginRequiredMiddleware = load_middleware(ConfFixture.BK_JWT_MIDDLEWARE)
