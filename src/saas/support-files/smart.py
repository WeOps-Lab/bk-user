import jinja2

template_loader = jinja2.FileSystemLoader('.')
template_env = jinja2.Environment(loader=template_loader)

pkgs = {}
with open('./requirements.txt', "r", encoding='utf-8') as f:
    lines = f.readlines()
    for line in lines:
        if len(line) == 0:
            continue
        if line[0] == "#":
            continue
        values = line.split("==")
        if len(values) != 2:
            continue
        pkgs[values[0]] = values[1]

dynamic_dict = {
    'pkgs': pkgs
}
app_template = template_env.get_template('support-files/smart/templates/app.yml')
with open('./app.yml', "w", encoding='utf-8') as f:
    app = app_template.render(dynamic_dict)
    f.writelines(app)