add_rules('mode.release', 'mode.debug', 'mode.releasedbg')

set_languages('cxx17', 'c11')
set_warnings('all')
set_exceptions('cxx')

if is_mode('releasedbg') then
    set_symbols('debug')
    set_optimize('fast')
end

target('bili_plugin')
    set_kind('shared')
    add_rules('qt.shared')

    add_files('src/*.cpp')
    add_files('src/modules/**/*.cpp')
    add_files('src/*.h')
    add_files('src/modules/**/*.h')
    add_includedirs('src')

    add_frameworks(
        'QtCore',
        'QtQuick',
        'QtQml',
        'QtNetwork',
        'QtMultimedia',
        'QtGui'
    )
