"""Read local reference PDFs; persist only schema and aggregate quality counts."""
import argparse
import json
import logging
import re
from pathlib import Path
import pdfplumber


def inspect(operation_path, maintenance_path):
    logging.disable(logging.WARNING)
    vehicles = {}
    with pdfplumber.open(operation_path) as pdf:
        operation_pages = len(pdf.pages)
        for page in pdf.pages:
            for table in page.extract_tables():
                for row in table:
                    if row[0] and re.fullmatch(r'37A\d{4}', row[0]):
                        vehicles[row[0]] = int(row[1])
    count = missing = before_year = 0
    no_table_pages = []
    with pdfplumber.open(maintenance_path) as pdf:
        maintenance_pages = len(pdf.pages)
        for i, page in enumerate(pdf.pages, 1):
            tables = page.extract_tables()
            if not tables:
                no_table_pages.append(i)
            for table in tables:
                for row in table:
                    if row[0] and re.fullmatch(r'37A\d{4}', row[0]):
                        count += 1
                        year = vehicles.get(row[0])
                        missing += year is None
                        before_year += year is not None and int(row[1][:4]) < year
    return {
        'referenceUse': 'schema only; no original rows, identifiers or descriptions exported',
        'operation': {'pages': operation_pages, 'rows': len(vehicles),
            'fields': ['차량 부여번호', '출고 연도(년)', '주행 거리(km)', '주행 시간(H)', '유류 사용량(L)']},
        'maintenance': {'pages': maintenance_pages, 'rows': count,
            'fields': ['차량 부여번호', '정비 일자', '고장 수리부속 품명', '가격', '정비 내용'],
            'pagesWithoutTables': no_table_pages, 'rowsWithoutOperationVehicle': missing,
            'rowsBeforeVehicleReleaseYear': before_year},
        'notPresent': ['fault ground truth', 'sensor measurements', 'inspection images', 'manual text'],
    }


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('operations', type=Path)
    parser.add_argument('maintenance', type=Path)
    args = parser.parse_args()
    result = inspect(args.operations, args.maintenance)
    out = Path('data/mock/reference_schema.json')
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding='utf-8')
    print(json.dumps(result, ensure_ascii=False, indent=2))
