import os

# Nome do volume
volume_name = 'MacProcess'

# Imagem de fundo
background = 'Assets.xcassets/dmg_background.png'

# Ícone do volume
badge_icon = 'Assets.xcassets/AppIcon.icns'

# Janela do instalador
window_rect = ((200, 120), (660, 400))

# Visualização de ícones
default_view = 'icon-view'
show_toolbar = False
show_statusbar = False
show_sidebar = False
show_tab_view = False
icon_size = 100

# Arquivos e links
files = ['MacProcess.app']
symlinks = {'Applications': '/Applications'}

# Posições dos ícones: MacProcess à esquerda, Applications à direita
icon_locations = {
    'MacProcess.app': (170, 190),
    'Applications': (490, 190)
}
